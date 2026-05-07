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

--- A custom asynchronous finder that doesn't block the UI thread.
local AsyncConfluenceFinder = setmetatable({
  close = function(self)
    self._current_req = (self._current_req or 0) + 1
  end,
}, {
  __call = function(cls, opts)
    return setmetatable({
      api = opts.api,
      space_key = opts.space_key,
      entry_maker = make_entry,
      _current_req = 0,
    }, {
      __index = cls
    })
  end
})

function AsyncConfluenceFinder:_find(prompt, process_result, process_complete)
  self._current_req = self._current_req + 1
  local req_id = self._current_req

  if not prompt or prompt == '' then
    process_complete()
    return
  end

  self.api.search_pages(prompt, self.space_key, function(results, err)
    -- If a new request was started or the finder was closed, ignore this callback.
    if self._current_req ~= req_id then return end

    if not results then
      vim.schedule(function()
        vim.notify('Search failed: ' .. (err or ''), vim.log.levels.ERROR)
      end)
    else
      for i, page in ipairs(results) do
        local entry = self.entry_maker(page)
        if entry then
          entry.index = i
          if process_result(entry) then
            return
          end
        end
      end
    end
    process_complete()
  end)
end

--- Live-search Confluence pages using an async dynamic finder.
--- @param api table  convim.api module (passed in for testability)
--- @param space_key string|nil  optional space scope
--- @param initial_query string|nil
--- @param on_select function(page)
--- @return boolean ok  false if telescope isn't available
function M.search_pages(api, space_key, initial_query, on_select)
  if not M.available() then return false end

  local pickers       = require('telescope.pickers')
  local conf          = require('telescope.config').values
  local actions       = require('telescope.actions')
  local action_state  = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Confluence: search pages' .. (space_key and (' [' .. space_key .. ']') or ''),
    default_text = initial_query or '',
    finder = AsyncConfluenceFinder({
      api = api,
      space_key = space_key,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        -- Double-schedule to ensure telescope has fully torn down its
        -- prompt buffer/window before on_select creates new buffers.
        -- A single vim.schedule only defers one event-loop tick, which
        -- isn't enough for telescope's async cleanup.
        if entry and entry.value then
          vim.schedule(function()
            vim.schedule(function() on_select(entry.value) end)
          end)
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
          vim.schedule(function()
            vim.schedule(function() on_select(entry.value) end)
          end)
        end
      end)
      return true
    end,
  }):find()

  return true
end

return M
