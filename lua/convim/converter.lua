local http = require('plenary.http')
local config = require('convim.config')

local M = {}

--- Convert a Markdown string to Confluence storage format (XHTML) using the
--- Confluence render API.  Returns the converted string, or nil + error_msg.
M.to_storage = function(markdown_content)
  local err = config.validate()
  if err then return nil, err end

  local url = string.format('%s/wiki/api/v2/pages/render', config.base_url)
  local response = http.post(url, {
    headers = {
      ['Authorization'] = 'Bearer ' .. config.token,
      ['Accept'] = 'application/json',
      ['Content-Type'] = 'application/json',
    },
    body = vim.fn.json_encode({
      value = markdown_content,
      representation = 'markdown',
    }),
  })

  if not response or response.status ~= 200 then
    local status = response and response.status or 'no response'
    return nil, string.format('HTTP %s from render endpoint', status)
  end

  local ok, data = pcall(vim.fn.json_decode, response.body)
  if not ok or not data.value then
    return nil, 'Failed to decode render response'
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
