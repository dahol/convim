local http = require('plenary.http')
local config = require('convim.config')

local M = {}

--- Build the standard auth/accept headers.
local function headers(extra)
  local h = {
    ['Authorization'] = 'Bearer ' .. (config.token or ''),
    ['Accept'] = 'application/json',
  }
  if extra then
    for k, v in pairs(extra) do h[k] = v end
  end
  return h
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

    local response = http.get(paged_url, { headers = opts.headers })
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
--- Makes a single lightweight GET to /wiki/api/v2/spaces?limit=1 and reports:
---   - The authenticated user's display name (from the X-Ausername header or
---     a separate /wiki/rest/api/user/current call)
---   - The base URL being used
---   - The HTTP status returned
--- Returns a result table { ok, user, status, message }, never raises.
M.verify_auth = function()
  local cfg_err = config.validate()
  if cfg_err then
    return { ok = false, message = cfg_err }
  end

  -- Probe the spaces endpoint with limit=1 — cheap and requires auth
  local probe_url = config.base_url .. '/wiki/api/v2/spaces?limit=1'
  local ok, response = pcall(http.get, probe_url, { headers = headers() })

  if not ok then
    -- pcall caught a Lua error (e.g. network completely unreachable)
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
  local u_ok, u_resp = pcall(http.get, user_url, { headers = headers() })
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
--- Returns list, error_msg
M.get_spaces = function()
  local err = config.validate()
  if err then return nil, err end

  local url = string.format('%s/wiki/api/v2/spaces', config.base_url)
  return fetch_all(url, { headers = headers() })
end

--- Return all pages in the given space.
--- Returns list, error_msg
M.get_pages = function(space_key)
  local err = config.validate()
  if err then return nil, err end

  local url = string.format('%s/wiki/api/v2/spaces/%s/pages', config.base_url, space_key)
  return fetch_all(url, { headers = headers() })
end

--- Search pages by title in the current space (or globally if space_key is nil).
--- Returns list, error_msg
M.search_pages = function(query, space_key)
  local err = config.validate()
  if err then return nil, err end

  local cql = string.format('type=page AND title~"%s"', query)
  if space_key and space_key ~= '' then
    cql = cql .. string.format(' AND space.key="%s"', space_key)
  end

  local url = string.format('%s/wiki/rest/api/content/search?cql=%s',
    config.base_url, vim.fn.shellescape and vim.uri_encode and vim.uri_encode(cql) or cql)

  local response = http.get(url, { headers = headers() })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s', status)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode search response' end
  return data.results or {}, nil
end

--- Fetch a single page with its body in storage format.
--- Returns page table, error_msg
M.get_page_content = function(page_id)
  local err = config.validate()
  if err then return nil, err end

  local url = string.format('%s/wiki/api/v2/pages/%s?body-format=storage', config.base_url, page_id)
  local response = http.get(url, { headers = headers() })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s fetching page %s', status, page_id)
  end
  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok then return nil, 'Failed to decode page response' end
  return data, nil
end

--- Create a new page in the given space under the given parent (optional).
--- Returns the created page table, error_msg
M.create_page = function(space_key, title, content, parent_id)
  local err = config.validate()
  if err then return nil, err end

  local url = string.format('%s/wiki/api/v2/pages', config.base_url)
  local payload = {
    spaceId = space_key,
    title = title,
    body = {
      storage = { value = content, representation = 'storage' },
    },
  }
  if parent_id then
    payload.parentId = parent_id
  end

  local response = http.post(url, {
    headers = headers({ ['Content-Type'] = 'application/json' }),
    body = vim.fn.json_encode(payload),
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
--- Returns true, nil on success; nil, error_msg on failure.
M.update_page = function(page_id, title, content)
  -- First fetch the current version number
  local page, fetch_err = M.get_page_content(page_id)
  if not page then
    return nil, 'Could not fetch page to determine version: ' .. (fetch_err or '')
  end

  local current_version = page.version and page.version.number or 0
  local url = string.format('%s/wiki/api/v2/pages/%s', config.base_url, page_id)

  local payload = {
    id = page_id,
    title = title,
    body = {
      storage = { value = content, representation = 'storage' },
    },
    version = { number = current_version + 1 },
  }

  local response = http.put(url, {
    headers = headers({ ['Content-Type'] = 'application/json' }),
    body = vim.fn.json_encode(payload),
  })
  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s updating page %s', status, page_id)
  end
  return true, nil
end

return M
