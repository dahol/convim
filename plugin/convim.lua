local convim = require('convim')
local ui = require('convim.ui')

vim.api.nvim_create_user_command('ConfluenceVerifyAuth', function()
  vim.notify('convim: checking auth…', vim.log.levels.INFO)

  local result = convim.api.verify_auth()

  if result.ok then
    vim.notify(
      string.format('convim: OK — %s', result.message),
      vim.log.levels.INFO
    )
  else
    vim.notify(
      string.format('convim: auth check failed — %s', result.message),
      vim.log.levels.ERROR
    )
  end
end, { desc = 'Verify that the configured Confluence credentials work' })

vim.api.nvim_create_user_command('ConfluenceListSpaces', function()
  ui.list_spaces()
end, { desc = 'List and select a Confluence space' })

vim.api.nvim_create_user_command('ConfluenceListPages', function()
  ui.list_pages()
end, { desc = 'List pages in the current space' })

vim.api.nvim_create_user_command('ConfluenceEdit', function(args)
  local page_id = vim.trim(args.args)
  if page_id ~= '' then
    ui.edit_page(page_id)
  else
    ui.list_pages()
  end
end, {
  nargs = '?',
  desc = 'Edit a Confluence page by ID, or pick from list',
})

vim.api.nvim_create_user_command('ConfluenceEditRaw', function(args)
  local page_id = vim.trim(args.args)
  if page_id == '' then
    vim.notify('Usage: :ConfluenceEditRaw <page_id>', vim.log.levels.WARN)
    return
  end
  ui.edit_page_raw(page_id)
end, {
  nargs = 1,
  desc = 'Edit a Confluence page as raw storage XHTML (no markdown round-trip)',
})

vim.api.nvim_create_user_command('ConfluenceNew', function(args)
  local title = vim.trim(args.args)
  ui.new_page(title ~= '' and title or nil)
end, {
  nargs = '?',
  desc = 'Create a new Confluence page',
})

vim.api.nvim_create_user_command('ConfluenceSearch', function(args)
  local query = vim.trim(args.args)
  ui.search_pages(query ~= '' and query or nil)
end, {
  nargs = '?',
  desc = 'Search Confluence pages by title (shows cached list if available)',
})

vim.api.nvim_create_user_command('ConfluenceScan', function()
  local err = convim.config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end
  
  vim.notify('Scanning Confluence... this may take a moment.', vim.log.levels.INFO)
  
  local pages, scan_err = convim.api.scan_all_pages()
  if not pages then
    vim.notify('Scan failed: ' .. (scan_err or ''), vim.log.levels.ERROR)
    return
  end
  
  ui.set_cache(pages, os.date('%Y-%m-%d %H:%M:%S'))
  
  vim.notify(string.format(
    'Confluence scan complete: %d page(s) indexed. Last updated: %s',
    #pages, os.date('%Y-%m-%d %H:%M:%S')
  ), vim.log.levels.INFO)
end, { desc = 'Scan all Confluence spaces and index all pages' })

vim.api.nvim_create_user_command('ConfluenceListAll', function()
  local pages, timestamp = ui.get_cache()
  if not pages then
    vim.notify('No cached pages. Run :ConfluenceScan first, or use :ConfluenceSearch for immediate search.', vim.log.levels.INFO)
    return
  end
  
  local on_pick = function(page) ui.edit_page(page.id) end
  
  if #pages == 0 then
    vim.notify('No pages in cache', vim.log.levels.WARN)
    return
  end

  -- Prefer telescope picker; fall back to vim.ui.select
  if convim.picker.list_pages(pages, 'All indexed Confluence pages', on_pick) then
    return
  end

  vim.ui.select(pages, {
    prompt = 'Select a page (cached: ' .. (timestamp or 'unknown') .. '):',
    format_item = function(page)
      local space = page._space_key and ('[' .. page._space_key .. '] ') or ''
      return space .. (page.title or page.id)
    end,
  }, function(page)
    if page then on_pick(page) end
  end)
end, { desc = 'List all pages from last scan cache' })

vim.api.nvim_create_user_command('ConfluenceSave', function()
  ui.save_page()
end, { desc = 'Save the current Confluence buffer' })

vim.api.nvim_create_user_command('ConfluencePreview', function()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = table.concat(lines, '\n')

  local html, err = convim.converter.to_storage(content)
  if not html then
    vim.notify('Preview failed: ' .. (err or ''), vim.log.levels.ERROR)
    return
  end

  local plain = convim.converter.strip_html(html)
  local preview_lines = vim.split(plain, '\n', { plain = true })

  local preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(preview_buf)
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
  vim.bo[preview_buf].bufhidden  = 'wipe'
  vim.bo[preview_buf].buftype    = 'nofile'
  vim.bo[preview_buf].modifiable = false
  vim.notify('Preview ready', vim.log.levels.INFO)
end, { desc = 'Preview the current Confluence buffer as plain text' })
