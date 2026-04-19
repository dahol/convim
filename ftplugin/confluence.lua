-- Loaded for buffers with filetype=confluence (set either by ftdetect for
-- *.confluence files, or by convim itself when opening a page from the API).
--
-- We rely on `syntax/confluence.vim` (in this plugin) to provide the actual
-- highlighting on top of html.  See that file for what's concealed and folded.

local buf = vim.api.nvim_get_current_buf()

-- Buffer-local view options for readability.
-- Folding: storage is dense; fold each <ac:structured-macro> block.
vim.wo.foldmethod = 'syntax'
vim.wo.foldlevel  = 99            -- everything open by default; user can :zM
vim.wo.foldenable = true
-- Conceal: hide noisy bookkeeping attributes (ac:local-id, ac:schema-version,
-- ac:macro-id, data-layout) and CDATA wrappers.  Set conceallevel=0 to see
-- the raw storage XHTML.
vim.wo.conceallevel    = 2
vim.wo.concealcursor   = ''       -- show raw on the line under the cursor
-- Soft-wrap long lines (storage often has long <p> blocks even after pretty).
vim.wo.wrap        = true
vim.wo.linebreak   = true
vim.wo.breakindent = true

local ok, page_id = pcall(vim.api.nvim_buf_get_var, buf, 'confluence_page_id')

if ok and page_id then
  -- Buffer-local keymaps for pages opened via the plugin
  vim.keymap.set('n', '<leader>cs', '<cmd>ConfluenceSave<CR>',
    { buffer = buf, desc = 'Confluence: save page' })
  vim.keymap.set('n', '<leader>cp', '<cmd>ConfluencePreview<CR>',
    { buffer = buf, desc = 'Confluence: preview page' })
  -- Quick toggle for users who want to see the raw markup
  vim.keymap.set('n', '<leader>cc', function()
    vim.wo.conceallevel = vim.wo.conceallevel == 0 and 2 or 0
    vim.notify('conceallevel = ' .. vim.wo.conceallevel, vim.log.levels.INFO)
  end, { buffer = buf, desc = 'Confluence: toggle conceal of noise attrs' })
end
