-- Loaded for buffers with filetype=confluence (set either by ftdetect for
-- *.confluence files, or by convim itself when opening a page from the API).

-- Treat confluence buffers as markdown for syntax highlighting and LSP
vim.bo.syntax = 'markdown'

local buf = vim.api.nvim_get_current_buf()
local ok, page_id = pcall(vim.api.nvim_buf_get_var, buf, 'confluence_page_id')

if ok and page_id then
  -- Buffer-local keymaps for pages opened via the plugin
  vim.keymap.set('n', '<leader>cs', '<cmd>ConfluenceSave<CR>',
    { buffer = buf, desc = 'Confluence: save page' })
  vim.keymap.set('n', '<leader>cp', '<cmd>ConfluencePreview<CR>',
    { buffer = buf, desc = 'Confluence: preview page' })
end
