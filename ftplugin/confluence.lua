-- Loaded for buffers with filetype=confluence (set either by ftdetect for
-- *.confluence files, or by convim itself when opening a page from the API).

local buf = vim.api.nvim_get_current_buf()

-- Treat confluence buffers as html for syntax highlighting (buffer-local).
-- Storage format IS XHTML, so html highlighting is the closest builtin match.
-- Skip if the user has already configured something else.
if vim.bo[buf].syntax == '' or vim.bo[buf].syntax == 'confluence' then
  vim.bo[buf].syntax = 'html'
end

local ok, page_id = pcall(vim.api.nvim_buf_get_var, buf, 'confluence_page_id')

if ok and page_id then
  -- Buffer-local keymaps for pages opened via the plugin
  vim.keymap.set('n', '<leader>cs', '<cmd>ConfluenceSave<CR>',
    { buffer = buf, desc = 'Confluence: save page' })
  vim.keymap.set('n', '<leader>cp', '<cmd>ConfluencePreview<CR>',
    { buffer = buf, desc = 'Confluence: preview page' })
end
