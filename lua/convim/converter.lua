local curl = require('plenary.curl')
local config = require('convim.config')

local M = {}

--- Default HTTP request timeout in seconds.
local DEFAULT_TIMEOUT = 30

--- Convert a Markdown (or wiki-markup) string to Confluence storage format
--- (XHTML) using the contentbody/convert/storage endpoint.
--- Note: Confluence's converter accepts representations 'wiki', 'editor',
--- 'editor2', 'view' — *not* 'markdown' directly.  We send wiki markup, which
--- is the closest builtin representation; callers wanting true markdown should
--- pre-convert with an external tool.
--- Returns the converted string, or nil + error_msg.
M.to_storage = function(source, from_representation)
  local err = config.validate()
  if err then return nil, err end

  local auth, aerr = config.auth_header()
  if not auth then return nil, aerr end

  local url = string.format('%s/wiki/rest/api/contentbody/convert/storage', config.base_url)
  local response = curl.post(url, {
    headers = {
      ['Authorization'] = auth,
      ['Accept']        = 'application/json',
      ['Content-Type']  = 'application/json',
    },
    body = vim.fn.json_encode({
      value          = source,
      representation = from_representation or 'wiki',
    }),
    timeout = DEFAULT_TIMEOUT,
  })

  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s from convert endpoint', status)
  end

  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok or not data.value then
    return nil, 'Failed to decode convert response'
  end
  return data.value, nil
end

--- Strip HTML tags from a storage-format string to produce a readable plain-text
--- preview.  Used by :ConfluencePreview when a rendered diff is desired.
M.strip_html = function(html)
  if not html then return '' end
  -- Replace block-level tags with newlines to preserve paragraph structure
  local text = html
    :gsub('<br%s*/?>', '\n')
    :gsub('<p[^>]*>', '\n')
    :gsub('<h%d[^>]*>', '\n')
    :gsub('<li[^>]*>', '\n- ')
    :gsub('<[^>]+>', '')
  -- Collapse runs of blank lines
  text = text:gsub('\n\n\n+', '\n\n')
  return vim.trim(text)
end

return M
