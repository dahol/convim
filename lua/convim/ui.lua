local api = require('convim.api')
local config = require('convim.config')
local format = require('convim.format')
local picker = require('convim.picker')

local M = {}

--- Safely read a buffer variable; returns nil instead of throwing if unset.
local function buf_get_var(buf, name)
  local ok, val = pcall(vim.api.nvim_buf_get_var, buf, name)
  return ok and val or nil
end

--- Open a new scratch buffer and populate it with lines.
--- Sets the filetype and marks it as a Confluence buffer with the given metadata.
--- Uses buftype=acwrite + BufWriteCmd so plain `:w` (and `:wq`) save to Confluence.
local function open_confluence_buf(page_id, title, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  -- Give the buffer a unique, filesystem-safe pseudo-name so `:w` has a target
  -- and tabline/statusline display something meaningful.
  local safe_title = (title or 'untitled'):gsub('[^%w%-_.]+', '_')
  local bufname = string.format('confluence://%s/%s', page_id, safe_title)
  -- Avoid name collisions if the same page is opened twice
  if vim.fn.bufexists(bufname) == 1 then
    bufname = bufname .. '#' .. buf
  end
  vim.api.nvim_buf_set_name(buf, bufname)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].buftype   = 'acwrite'   -- 'we handle the write ourselves'
  vim.bo[buf].filetype  = 'confluence'
  vim.bo[buf].buflisted = true
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modified  = false
  vim.api.nvim_buf_set_var(buf, 'confluence_page_id', page_id)
  vim.api.nvim_buf_set_var(buf, 'confluence_title', title)

  -- Wire :w / :wq / :update to ConfluenceSave for this buffer only.
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    desc   = 'convim: save Confluence page on :w',
    callback = function() M.save_page() end,
  })

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

  vim.ui.select(spaces, {
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

  local on_pick = function(page) M.edit_page(page.id) end

  -- Prefer telescope floating picker; fall back to vim.ui.select.
  if picker.list_pages(pages, 'Confluence: ' .. config.space_key, on_pick) then
    return
  end

  vim.ui.select(pages, {
    prompt = 'Select a page to edit:',
    format_item = function(page) return page.title end,
  }, function(page)
    if page then on_pick(page) end
  end)
end

M.search_pages = function(query)
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  local on_pick = function(page) M.edit_page(page.id) end

  -- Telescope path: live, incremental search inside a floating window.
  -- The query (if any) seeds the prompt; further keystrokes re-query the API.
  if picker.search_pages(api, config.space_key, query, on_pick) then
    return
  end

  -- Fallback: prompt for a query, then list results via vim.ui.select.
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
    if page then on_pick(page) end
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

  -- Pretty-print storage XHTML for editing (newlines + indent, drop local-id).
  local pretty = format.pretty(storage_value)
  local lines = vim.split(pretty, '\n', { plain = true })
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
  -- New buffer is empty storage XHTML; the user can write storage markup or
  -- use :ConfluencePreview to convert from wiki markup before saving.
  return open_confluence_buf(page.id, title, { '' })
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
  -- Re-compact the pretty-printed buffer back to a single-line storage string
  -- before sending to Confluence.
  local content = format.compact(table.concat(lines, '\n'))

  local ok, update_err = api.update_page(page_id, title, content)
  if ok then
    vim.bo[buf].modified = false
    vim.notify('Saved: ' .. title, vim.log.levels.INFO)
  else
    vim.notify('Save failed: ' .. (update_err or ''), vim.log.levels.ERROR)
  end
end

return M
