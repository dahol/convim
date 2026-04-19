-- Telescope-based pickers for convim.
--
-- Provides:
--   search_pages(initial_query, on_select)
--       Live, incremental Confluence CQL search.  Each keystroke (debounced
--       by telescope) re-queries the API.  <CR> calls on_select(page).
--   list_pages(pages, on_select)
--       Static fuzzy picker over an already-fetched page list.
--
-- All functions are no-ops returning false if telescope.nvim is not
-- installed, letting the caller fall back to vim.ui.select.

local M = {}

--- True iff telescope.nvim can be required.
function M.available()
  local ok, _ = pcall(require, 'telescope')
  return ok
end

--- Build a telescope entry from a Confluence page table.
local function make_entry(page)
  local space = page.space and ('[' .. page.space.key .. '] ') or ''
  local title = page.title or page.id or '<untitled>'
  return {
    value   = page,
    display = space .. title,
    ordinal = space .. title,
  }
end

--- Live-search Confluence pages using telescope's dynamic finder.
--- @param api table  convim.api module (passed in for testability)
--- @param space_key string|nil  optional space scope
--- @param initial_query string|nil
--- @param on_select function(page)
--- @return boolean ok  false if telescope isn't available
function M.search_pages(api, space_key, initial_query, on_select)
  if not M.available() then return false end

  local pickers       = require('telescope.pickers')
  local finders       = require('telescope.finders')
  local conf          = require('telescope.config').values
  local actions       = require('telescope.actions')
  local action_state  = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Confluence: search pages' .. (space_key and (' [' .. space_key .. ']') or ''),
    default_text = initial_query or '',
    finder = finders.new_dynamic({
      fn = function(query)
        if not query or query == '' then return {} end
        local results, err = api.search_pages(query, space_key)
        if not results then
          vim.schedule(function()
            vim.notify('Search failed: ' .. (err or ''), vim.log.levels.ERROR)
          end)
          return {}
        end
        return results
      end,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        -- Defer until after telescope finishes tearing down its prompt
        -- buffer/window.  Otherwise creating a new buffer inside
        -- on_select can race with telescope's own buffer cleanup and
        -- produce 'Invalid buffer id' errors.
        if entry and entry.value then
          vim.schedule(function() on_select(entry.value) end)
        end
      end)
      return true
    end,
  }):find()

  return true
end

--- Fuzzy-pick from a static list of pages.
function M.list_pages(pages, title, on_select)
  if not M.available() then return false end

  local pickers       = require('telescope.pickers')
  local finders       = require('telescope.finders')
  local conf          = require('telescope.config').values
  local actions       = require('telescope.actions')
  local action_state  = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = title or 'Confluence pages',
    finder = finders.new_table({
      results     = pages,
      entry_maker = make_entry,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry and entry.value then
          vim.schedule(function() on_select(entry.value) end)
        end
      end)
      return true
    end,
  }):find()

  return true
end

return M
