local convim = require('convim')

vim.api.nvim_create_user_command('ConfluenceVerifyAuth', function()
  -- Show a spinner-like message while the request is in flight
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
  convim.ui.list_spaces()
end, { desc = 'List and select a Confluence space' })

vim.api.nvim_create_user_command('ConfluenceListPages', function()
  convim.ui.list_pages()
end, { desc = 'List pages in the current space' })

vim.api.nvim_create_user_command('ConfluenceEdit', function(args)
  local page_id = vim.trim(args.args)
  if page_id ~= '' then
    convim.ui.edit_page(page_id)
  else
    convim.ui.list_pages()
  end
end, {
  nargs = '?',
  desc = 'Edit a Confluence page by ID, or pick from list',
})

vim.api.nvim_create_user_command('ConfluenceNew', function(args)
  local title = vim.trim(args.args)
  convim.ui.new_page(title ~= '' and title or nil)
end, {
  nargs = '?',
  desc = 'Create a new Confluence page',
})

vim.api.nvim_create_user_command('ConfluenceSearch', function(args)
  local query = vim.trim(args.args)
  convim.ui.search_pages(query ~= '' and query or nil)
end, {
  nargs = '?',
  desc = 'Search Confluence pages by title',
})

vim.api.nvim_create_user_command('ConfluenceSave', function()
  convim.ui.save_page()
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
  vim.api.nvim_buf_set_option(preview_buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(preview_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(preview_buf, 'modifiable', false)
  vim.notify('Preview ready', vim.log.levels.INFO)
end, { desc = 'Preview the current Confluence buffer as plain text' })
