-- tests/test_ui.lua
-- Tests for lua/convim/ui.lua
-- Uses real vim.api (headless Neovim) but mocks out the HTTP layer.

package.loaded['convim.config']  = nil
package.loaded['convim.api']     = nil
package.loaded['convim.ui']      = nil
package.loaded['plenary.curl']   = nil

local config = require('convim.config')
config.base_url  = 'https://test.atlassian.net'
config.token     = 'test_tok'
config.space_key = 'TEST'

-- ── stubbed Confluence API ────────────────────────────────────────────────────

local stub_api = {
  get_spaces = function()
    return { { key = 'A', name = 'Alpha' }, { key = 'B', name = 'Beta' } }, nil
  end,
  get_pages = function(space_key)
    if space_key == 'TEST' then
      return { { id = '1', title = 'Page One' }, { id = '2', title = 'Page Two' } }, nil
    end
    return {}, nil
  end,
  get_page_content = function(page_id)
    if page_id == '1' then
      return {
        id = '1', title = 'Page One',
        version = { number = 5 },
        body = { storage = { value = '<p>Hello from page 1</p>' } },
      }, nil
    end
    return nil, 'not found'
  end,
  update_page = function(page_id, title, content)
    return true, nil
  end,
  create_page = function(space_key, title, content, parent_id)
    return { id = '99', title = title }, nil
  end,
  search_pages = function(query, space_key)
    if query == 'test' then
      return { { id = '3', title = 'Test Result', space = { key = 'A' } } }, nil
    end
    return {}, nil
  end,
}
package.loaded['convim.api'] = stub_api

-- ── helpers ───────────────────────────────────────────────────────────────────

local function reload_ui()
  package.loaded['convim.ui'] = nil
  return require('convim.ui')
end

local function get_buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function buf_var(buf, name)
  local ok, v = pcall(vim.api.nvim_buf_get_var, buf, name)
  return ok and v or nil
end

-- ── tests: module surface ─────────────────────────────────────────────────────

local ui = reload_ui()
assert(type(ui.list_spaces)   == 'function', 'ui: list_spaces is function')
assert(type(ui.list_pages)    == 'function', 'ui: list_pages is function')
assert(type(ui.edit_page)     == 'function', 'ui: edit_page is function')
assert(type(ui.new_page)      == 'function', 'ui: new_page is function')
assert(type(ui.search_pages)  == 'function', 'ui: search_pages is function')
assert(type(ui.save_page)     == 'function', 'ui: save_page is function')
print('  ui: module exposes expected functions')

-- ── tests: edit_page ──────────────────────────────────────────────────────────

local ui2 = reload_ui()
local prev_buf = vim.api.nvim_get_current_buf()
local new_buf = ui2.edit_page('1')
assert(new_buf ~= nil, 'edit_page: returns buffer handle')
assert(vim.api.nvim_buf_is_valid(new_buf), 'edit_page: returned buffer is valid')

-- Check buffer options
assert(vim.bo[new_buf].filetype == 'confluence',
  'edit_page: filetype is confluence')
assert(vim.bo[new_buf].buftype == 'acwrite',
  'edit_page: buftype is acwrite (so :w fires our BufWriteCmd)')

-- Check buffer vars
assert(buf_var(new_buf, 'confluence_page_id') == '1', 'edit_page: page_id var set')
assert(buf_var(new_buf, 'confluence_title') == 'Page One', 'edit_page: title var set')

-- Check buffer content
local lines = get_buf_lines(new_buf)
local content = table.concat(lines, '\n')
assert(content:find('Hello from page 1'), 'edit_page: page content in buffer')
print('  ui: edit_page() creates buffer with correct content and vars')

-- edit_page notifies and returns nil for unknown page
local ui3 = reload_ui()
local notified_level = nil
local orig_notify = vim.notify
vim.notify = function(_, level) notified_level = level end
local bad_buf = ui3.edit_page('nonexistent')
vim.notify = orig_notify
assert(bad_buf == nil, 'edit_page: returns nil for missing page')
assert(notified_level == vim.log.levels.ERROR, 'edit_page: emits ERROR notification for missing page')
print('  ui: edit_page() notifies on error and returns nil')

-- ── tests: save_page ──────────────────────────────────────────────────────────

-- Set up a confluence buffer
local ui4 = reload_ui()
local save_buf = ui4.edit_page('1')
-- Edit the buffer content
vim.bo[save_buf].modifiable = true
vim.api.nvim_buf_set_lines(save_buf, 0, -1, false, { '<p>Updated content</p>' })

local save_notify_msg = nil
local orig_notify2 = vim.notify
vim.notify = function(msg, _) save_notify_msg = msg end
ui4.save_page()
vim.notify = orig_notify2
assert(save_notify_msg ~= nil, 'save_page: emits notification')
assert(save_notify_msg:find('Saved') or save_notify_msg:find('Page One'),
  'save_page: success notification mentions page')
print('  ui: save_page() saves and notifies success')

-- save_page warns on non-confluence buffer
local ui5 = reload_ui()
local plain_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(plain_buf)
local warn_msg = nil
local orig_notify3 = vim.notify
vim.notify = function(msg, _) warn_msg = msg end
ui5.save_page()
vim.notify = orig_notify3
assert(warn_msg ~= nil and warn_msg:find('Not a Confluence'),
  'save_page: warns on non-confluence buffer')
print('  ui: save_page() warns on non-confluence buffer')

-- ── tests: :w triggers save via BufWriteCmd ──────────────────────────────────

local ui_w = reload_ui()
local w_buf = ui_w.edit_page('1')
vim.bo[w_buf].modifiable = true
vim.api.nvim_buf_set_lines(w_buf, 0, -1, false, { '<p>edited via :w</p>' })
vim.bo[w_buf].modified = true

local w_msg = nil
local orig_notify4 = vim.notify
vim.notify = function(msg, _) w_msg = msg end
-- :write fires BufWriteCmd, which our autocmd routes to save_page
vim.cmd('silent write')
vim.notify = orig_notify4

assert(w_msg ~= nil and w_msg:find('Saved'),
  ':w: BufWriteCmd autocmd routed to save_page (got: ' .. tostring(w_msg) .. ')')
assert(vim.bo[w_buf].modified == false,
  ':w: modified flag cleared after successful save')
print('  ui: :w triggers ConfluenceSave via BufWriteCmd and clears modified flag')

-- ── tests: list_spaces selects space ─────────────────────────────────────────

local ui6 = reload_ui()
-- Intercept vim.ui.select to auto-pick first item
local orig_select = vim.ui.select
vim.ui.select = function(items, opts, cb) cb(items[1]) end
config.space_key = nil
ui6.list_spaces()
vim.ui.select = orig_select
assert(config.space_key == 'A', 'list_spaces: sets config.space_key to selected key')
print('  ui: list_spaces() updates config.space_key on selection')
