local curl = require('plenary.curl')
local config = require('convim.config')

local M = {}

--- Default HTTP request timeout in milliseconds (plenary expects ms).
local DEFAULT_TIMEOUT = 30000

--- Build the standard auth/accept headers.
--- Returns headers table, or nil + err if auth could not be built.
local function headers(extra)
  local auth, err = config.auth_header()
  if not auth then return nil, err end
  local h = {
    ['Authorization'] = auth,
    ['Accept']        = 'application/json',
  }
  if extra then
    for k, v in pairs(extra) do h[k] = v end
  end
  return h, nil
end

--- URL-encode a string for use in a query parameter value.
local function url_encode(s)
  if vim.uri_encode then return vim.uri_encode(s) end
  return (s:gsub('[^%w%-_.~]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

--- Fetch all pages of a paginated Confluence v2 endpoint.
--- `url` should be the base URL (without cursor params).
--- Returns a flat list of all result objects, or nil + error message.
local function fetch_all(url, opts)
  local results = {}
  local cursor = nil

  while true do
    local paged_url = url
    local params = {}
    if cursor then table.insert(params, 'cursor=' .. cursor) end
    table.insert(params, 'limit=50')
    if #params > 0 then
      paged_url = url .. (url:find('?') and '&' or '?') .. table.concat(params, '&')
    end

    local response = curl.get(paged_url, { headers = opts.headers, timeout = DEFAULT_TIMEOUT })
    if not response or response.status ~= 200 then
      local msg = (response and response.status) or 'no response'
      return nil, string.format('HTTP %s from %s', msg, paged_url)
    end

    local ok, data = pcall(vim.fn.json_decode, response.body)
    if not ok then
      return nil, 'Failed to decode JSON response'
    end

    for _, item in ipairs(data.results or {}) do
      table.insert(results, item)
    end

    -- Follow pagination cursor if present
    local next_link = data._links and data._links.next
    if not next_link then break end
    cursor = next_link:match('cursor=([^&]+)')
    if not cursor then break end
  end

  return results, nil
end

--- Verify that the configured credentials can reach the Confluence instance.
--- Returns a result table { ok, user, status, message }, never raises.
M.verify_auth = function()
  local cfg_err = config.validate()
  if cfg_err then
    return { ok = false, message = cfg_err }
  end

  local hdrs, herr = headers()
  if not hdrs then
    return { ok = false, message = herr }
  end

  -- Probe the spaces endpoint with limit=1 — cheap and requires auth
  local probe_url = config.base_url .. '/wiki/api/v2/spaces?limit=1'
  local ok, response = pcall(curl.get, probe_url, { headers = hdrs, timeout = DEFAULT_TIMEOUT })

  if not ok then
    return {
      ok = false,
      message = 'Network error: ' .. tostring(response),
    }
  end

  if not response then
    return { ok = false, message = 'No response from server' }
  end

  if response.status == 401 then
    return {
      ok = false,
      status = 401,
      message = 'Authentication failed (401): token is invalid or expired',
    }
  end

  if response.status == 403 then
    return {
      ok = false,
      status = 403,
      message = 'Authorisation denied (403): token lacks permission to read spaces',
    }
  end

  if response.status ~= 200 then
    return {
      ok = false,
      status = response.status,
      message = string.format('Unexpected HTTP %d from %s', response.status, probe_url),
    }
  end

  -- Auth succeeded — fetch the current user for a friendly confirmation
  local user = 'unknown'
  local user_url = config.base_url .. '/wiki/rest/api/user/current'
  local u_ok, u_resp = pcall(curl.get, user_url, { headers = hdrs, timeout = DEFAULT_TIMEOUT })
  if u_ok and u_resp and u_resp.status == 200 then
    local dec_ok, data = pcall(vim.fn.json_decode, u_resp.body)
    if dec_ok and data then
      user = data.displayName or data.publicName or data.username or user
    end
  end

  return {
    ok = true,
    status = 200,
    user = user,
    base_url = config.base_url,
    message = string.format('Authenticated as %s at %s', user, config.base_url),
  }
end

--- Return all spaces the token has access to.
M.get_spaces = function()
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers()
  if not hdrs then return nil, herr end

  local url = string.format('%s/wiki/api/v2/spaces', config.base_url)
  return fetch_all(url, { headers = hdrs })
end

--- Resolve a human-readable space key (e.g. "ENG") to the numeric v2 space ID.
--- Confluence v2 endpoints that mutate or filter by space require the ID,
--- not the key.  Returns id (string), nil on success; nil, err on failure.
M.get_space_id_by_key = function(space_key)
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers()
  if not hdrs then return nil, herr end

  local url = string.format('%s/wiki/api/v2/spaces?keys=%s&limit=1',
    config.base_url, url_encode(space_key))
  local response = curl.get(url, { headers = hdrs, timeout = DEFAULT_TIMEOUT })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s resolving space key %s', status, space_key)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode space lookup response' end
  local first = data.results and data.results[1]
  if not first or not first.id then
    return nil, string.format('No space found with key %q', space_key)
  end
  return tostring(first.id), nil
end

--- Return all pages in the given space (accepts space key; resolves to ID).
M.get_pages = function(space_key)
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers()
  if not hdrs then return nil, herr end

  local space_id, sid_err = M.get_space_id_by_key(space_key)
  if not space_id then return nil, sid_err end

  local url = string.format('%s/wiki/api/v2/spaces/%s/pages', config.base_url, space_id)
  return fetch_all(url, { headers = hdrs })
end

--- Scan and cache all pages across all accessible spaces.
M.scan_all_pages = function()
  local err = config.validate()
  if err then return nil, err end

  local spaces, spaces_err = M.get_spaces()
  if not spaces then return nil, 'Failed to fetch spaces: ' .. (spaces_err or '') end

  local all_pages = {}

  for _, space in ipairs(spaces) do
    local pages, pages_err = M.get_pages(space.key)
    if pages then
      for _, page in ipairs(pages) do
        page._space_key = space.key
        table.insert(all_pages, page)
      end
    end
  end

  return all_pages, nil
end

--- Search pages by title in the current space (or globally if space_key is nil).
--- If `cb` is provided, executes asynchronously and calls `cb(results, err)`.
M.search_pages = function(query, space_key, cb)
  local err = config.validate()
  if err then
    if cb then return cb(nil, err) else return nil, err end
  end

  local hdrs, herr = headers()
  if not hdrs then
    if cb then return cb(nil, herr) else return nil, herr end
  end

  -- Escape embedded double quotes inside the CQL value.
  local safe_q = query:gsub('"', '\\\"')
  local cql = string.format('type=page AND title~"%s"', safe_q)
  if space_key and space_key ~= '' then
    cql = cql .. string.format(' AND space.key="%s"', space_key)
  end

  local url = string.format('%s/wiki/rest/api/content/search?cql=%s',
    config.base_url, url_encode(cql))

  if cb then
    curl.get(url, {
      headers = hdrs,
      timeout = DEFAULT_TIMEOUT,
      callback = function(response)
        vim.schedule(function()
          if not response or response.status ~= 200 then
            local status = response and response.status or 'no response'
            cb(nil, string.format('HTTP %s', status))
            return
          end
          local ok, data = pcall(vim.fn.json_decode, response.body)
          if not ok then
            cb(nil, 'Failed to decode search response')
            return
          end
          cb(data.results or {}, nil)
        end)
      end
    })
    return
  end

  local response = curl.get(url, { headers = hdrs, timeout = DEFAULT_TIMEOUT })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s', status)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode search response' end
  return data.results or {}, nil
end


--- Fetch a single page with its body in storage format.
M.get_page_content = function(page_id)
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers()
  if not hdrs then return nil, herr end

  local url = string.format('%s/wiki/api/v2/pages/%s?body-format=storage', config.base_url, page_id)
  local response = curl.get(url, { headers = hdrs, timeout = DEFAULT_TIMEOUT })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s fetching page %s', status, page_id)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode page response' end
  return data, nil
end

--- Create a new page in the given space (key) under the given parent (optional).
--- Resolves space key → space ID before POSTing.
M.create_page = function(space_key, title, content, parent_id)
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers({ ['Content-Type'] = 'application/json' })
  if not hdrs then return nil, herr end

  local space_id, sid_err = M.get_space_id_by_key(space_key)
  if not space_id then return nil, sid_err end

  local url = string.format('%s/wiki/api/v2/pages', config.base_url)
  local payload = {
    spaceId = space_id,
    status  = 'current',
    title   = title,
    body    = {
      representation = 'storage',
      value          = content,
    },
  }
  if parent_id then
    payload.parentId = tostring(parent_id)
  end

  local response = curl.post(url, {
    headers = hdrs,
    body    = vim.fn.json_encode(payload),
    timeout = DEFAULT_TIMEOUT,
  })
  if not response or (response.status ~= 200 and response.status ~= 201) then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s creating page', status)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode create response' end
  return data, nil
end

--- Update an existing page. Automatically fetches the current version and increments it.
M.update_page = function(page_id, title, content)
  local err = config.validate()
  if err then return nil, err end

  local hdrs, herr = headers({ ['Content-Type'] = 'application/json' })
  if not hdrs then return nil, herr end

  -- First fetch the current version number
  local page, fetch_err = M.get_page_content(page_id)
  if not page then
    return nil, 'Could not fetch page to determine version: ' .. (fetch_err or '')
  end

  local current_version = page.version and page.version.number or 0
  local url = string.format('%s/wiki/api/v2/pages/%s', config.base_url, page_id)

  local payload = {
    id      = tostring(page_id),
    status  = 'current',
    title   = title,
    body    = {
      representation = 'storage',
      value          = content,
    },
    version = { number = current_version + 1 },
  }

  local response = curl.put(url, {
    headers = hdrs,
    body    = vim.fn.json_encode(payload),
    timeout = DEFAULT_TIMEOUT,
  })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s updating page %s', status, page_id)
  end
  return true, nil
end

return M
