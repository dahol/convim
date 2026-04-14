local api = require('convim.api')
local config = require('convim.config')

local M = {}

--- Safely read a buffer variable; returns nil instead of throwing if unset.
local function buf_get_var(buf, name)
  local ok, val = pcall(vim.api.nvim_buf_get_var, buf, name)
  return ok and val or nil
end

--- Open a new scratch buffer and populate it with lines.
--- Sets the filetype and marks it as a Confluence buffer with the given metadata.
local function open_confluence_buf(page_id, title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'confluence')
  vim.api.nvim_buf_set_option(buf, 'buflisted', false)
  vim.api.nvim_buf_set_var(buf, 'confluence_page_id', page_id)
  vim.api.nvim_buf_set_var(buf, 'confluence_title', title)
  return buf
end

M.list_spaces = function()
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  local spaces, fetch_err = api.get_spaces()
  if not spaces then
    vim.notify('Failed to fetch spaces: ' .. (fetch_err or ''), vim.log.levels.ERROR)
    return
  end

  if #spaces == 0 then
    vim.notify('No spaces found', vim.log.levels.WARN)
    return
  end

  -- Build display list, keeping the original space objects for reference
  local items = {}
  for _, space in ipairs(spaces) do
    table.insert(items, space)
  end

  vim.ui.select(items, {
    prompt = 'Select a Confluence space:',
    format_item = function(space)
      return string.format('[%s] %s', space.key, space.name or space.key)
    end,
  }, function(space)
    if space then
      config.space_key = space.key
      vim.notify('Space selected: ' .. space.key, vim.log.levels.INFO)
    end
  end)
end

M.list_pages = function()
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  if not config.space_key then
    vim.notify('No space selected. Run :ConfluenceListSpaces first.', vim.log.levels.WARN)
    return
  end

  local pages, fetch_err = api.get_pages(config.space_key)
  if not pages then
    vim.notify('Failed to fetch pages: ' .. (fetch_err or ''), vim.log.levels.ERROR)
    return
  end

  if #pages == 0 then
    vim.notify('No pages found in space ' .. config.space_key, vim.log.levels.WARN)
    return
  end

  vim.ui.select(pages, {
    prompt = 'Select a page to edit:',
    format_item = function(page) return page.title end,
  }, function(page)
    if page then M.edit_page(page.id) end
  end)
end

M.search_pages = function(query)
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  if not query or query == '' then
    vim.ui.input({ prompt = 'Search pages: ' }, function(input)
      if input and input ~= '' then M.search_pages(input) end
    end)
    return
  end

  local results, search_err = api.search_pages(query, config.space_key)
  if not results then
    vim.notify('Search failed: ' .. (search_err or ''), vim.log.levels.ERROR)
    return
  end

  if #results == 0 then
    vim.notify('No pages found matching: ' .. query, vim.log.levels.WARN)
    return
  end

  vim.ui.select(results, {
    prompt = 'Search results:',
    format_item = function(page)
      local space = page.space and ('[' .. page.space.key .. '] ') or ''
      return space .. (page.title or page.id)
    end,
  }, function(page)
    if page then M.edit_page(page.id) end
  end)
end

M.edit_page = function(page_id)
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  local page, fetch_err = api.get_page_content(page_id)
  if not page then
    vim.notify('Failed to fetch page: ' .. (fetch_err or ''), vim.log.levels.ERROR)
    return
  end

  local title = page.title or 'Untitled'
  local storage_value = (page.body and page.body.storage and page.body.storage.value) or ''

  -- Split storage content into lines for the buffer
  local lines = vim.split(storage_value, '\n', { plain = true })
  return open_confluence_buf(page_id, title, lines)
end

M.new_page = function(title, parent_id)
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  if not config.space_key then
    vim.notify('No space selected. Run :ConfluenceListSpaces first.', vim.log.levels.WARN)
    return
  end

  if not title or title == '' then
    vim.ui.input({ prompt = 'New page title: ' }, function(input)
      if input and input ~= '' then M.new_page(input, parent_id) end
    end)
    return
  end

  local page, create_err = api.create_page(config.space_key, title, '', parent_id)
  if not page then
    vim.notify('Failed to create page: ' .. (create_err or ''), vim.log.levels.ERROR)
    return
  end

  vim.notify('Created page: ' .. title, vim.log.levels.INFO)
  return open_confluence_buf(page.id, title, { '-- ' .. title, '' })
end

M.save_page = function()
  local buf = vim.api.nvim_get_current_buf()
  local page_id = buf_get_var(buf, 'confluence_page_id')

  if not page_id then
    vim.notify('Not a Confluence buffer', vim.log.levels.WARN)
    return
  end

  local title = buf_get_var(buf, 'confluence_title') or 'Untitled'
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  local ok, update_err = api.update_page(page_id, title, content)
  if ok then
    vim.notify('Saved: ' .. title, vim.log.levels.INFO)
  else
    vim.notify('Save failed: ' .. (update_err or ''), vim.log.levels.ERROR)
  end
end

return M
