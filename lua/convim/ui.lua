local api = require('convim.api')
local config = require('convim.config')
local format = require('convim.format')
local markdown = require('convim.markdown')
local picker = require('convim.picker')

local M = {}

--- Safely read a buffer variable; returns nil instead of throwing if unset.
local function buf_get_var(buf, name)
  local ok, val = pcall(vim.api.nvim_buf_get_var, buf, name)
  return ok and val or nil
end

--- Open (or focus, if already open) a Confluence buffer and populate it.
--- `opts` may contain:
---   mode  = 'markdown' (default) or 'storage'
---   meta  = the meta table returned by markdown.from_storage (only required
---           in markdown mode so the save path can rebuild storage XHTML).
local function open_confluence_buf(page_id, title, lines, opts)
  opts = opts or {}
  local mode = opts.mode or 'markdown'
  local safe_title = (title or 'untitled'):gsub('[^%w%-_.]+', '_')
  local ext = (mode == 'markdown') and 'md' or 'xhtml'
  local bufname = string.format('confluence://%s/%s.%s', page_id, safe_title, ext)

  -- Find a "normal" window to display the buffer in: skip floating windows
  -- (telescope leftovers) and special sidebars like neo-tree / NvimTree /
  -- aerial that the user almost certainly doesn't want clobbered.
  local function pick_target_win()
    local cur = vim.api.nvim_get_current_win()
    local function is_normal(win)
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative and cfg.relative ~= '' then return false end
      local b  = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[b].buftype
      local ft = vim.bo[b].filetype
      if bt == 'nofile' or bt == 'prompt' or bt == 'quickfix' or bt == 'help' then
        return false
      end
      if ft == 'neo-tree' or ft == 'NvimTree' or ft == 'aerial'
         or ft == 'TelescopePrompt' or ft == 'TelescopeResults' then
        return false
      end
      return true
    end
    if is_normal(cur) then return cur end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if is_normal(w) then return w end
    end
    -- No normal window found: open a new split.
    vim.cmd('botright vsplit')
    return vim.api.nvim_get_current_win()
  end

  -- If we already have a live buffer for this page, focus and refresh it
  -- rather than creating a duplicate (which would E5108 on nvim_buf_set_name).
  local existing = vim.fn.bufnr(bufname)
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    local target = pick_target_win()
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_win_set_buf(target, existing)
    vim.bo[existing].modifiable = true
    vim.api.nvim_buf_set_lines(existing, 0, -1, false, lines)
    if opts.meta then
      vim.api.nvim_buf_set_var(existing, 'confluence_meta', opts.meta)
    end
    vim.bo[existing].modified = false
    return existing
  end

  local buf = vim.api.nvim_create_buf(true, false)
  -- IMPORTANT: disable swapfile + set buftype BEFORE naming the buffer.
  -- Otherwise Neovim may attempt to create ~/.local/state/nvim/swap/<name>.swp
  -- and the next open of the same page will trigger E325 (ATTENTION swap exists).
  vim.bo[buf].swapfile  = false
  vim.bo[buf].buftype   = 'acwrite'   -- 'we handle the write ourselves'
  vim.bo[buf].buflisted = true

  vim.api.nvim_buf_set_name(buf, bufname)
  -- Populate before showing.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_var(buf, 'confluence_page_id', page_id)
  vim.api.nvim_buf_set_var(buf, 'confluence_title', title)
  vim.api.nvim_buf_set_var(buf, 'confluence_mode', mode)
  if opts.meta then
    vim.api.nvim_buf_set_var(buf, 'confluence_meta', opts.meta)
  end

  -- Display in a sensible window (not neo-tree, not telescope leftovers),
  -- THEN set filetype.  Setting filetype triggers ftplugin/<ft>.lua,
  -- whose window-local options apply to whatever window is current at that
  -- moment.
  local target = pick_target_win()
  vim.api.nvim_set_current_win(target)
  vim.api.nvim_win_set_buf(target, buf)
  vim.bo[buf].filetype = (mode == 'markdown') and 'markdown' or 'confluence'
  vim.bo[buf].modified = false

  -- Wire :w / :wq / :update to ConfluenceSave for this buffer only.
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    desc   = 'convim: save Confluence page on :w',
    callback = function() M.save_page() end,
  })

  return buf
end

--- Page cache for scanned results
local cached_pages = nil
local cache_timestamp = nil

--- Search result cache (query -> pages mapping)
local search_cache = {}
local MAX_SEARCH_CACHE_AGE = 300 -- 5 minutes in seconds

--- Set the page cache (for scan results)
M.set_cache = function(pages, timestamp)
  cached_pages = pages
  cache_timestamp = timestamp
end

--- Get the cached pages and timestamp
M.get_cache = function()
  return cached_pages, cache_timestamp
end

--- Store search results in cache
local function cache_search_results(query, space_key, results)
  local key = query .. '|' .. (space_key or '')
  search_cache[key] = {
    results = results,
    timestamp = os.time(),
  }
end

--- Get cached search results if not expired
local function get_cached_search_results(query, space_key)
  local key = query .. '|' .. (space_key or '')
  local cached = search_cache[key]
  if not cached then return nil end
  
  local age = os.difftime(os.time(), cached.timestamp)
  if age > MAX_SEARCH_CACHE_AGE then
    return nil
  end
  
  return cached.results
end

--- Clear old cache entries
local function cleanup_old_search_cache()
  local current_time = os.time()
  for key, cached in pairs(search_cache) do
    local age = os.difftime(current_time, cached.timestamp)
    if age > MAX_SEARCH_CACHE_AGE then
      search_cache[key] = nil
    end
  end
end

local function refresh_cache()
  local pages, err = api.scan_all_pages()
  if pages then
    cached_pages = pages
    cache_timestamp = os.date('%Y-%m-%d %H:%M:%S')
    return true
  else
    vim.notify('Failed to scan Confluence: ' .. (err or ''), vim.log.levels.ERROR)
    return false
  end
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

  -- If no query provided, show all cached pages (or scan first if cache is empty)
  if not query or query == '' then
    if not cached_pages then
      vim.notify('Fetching Confluence pages...', vim.log.levels.INFO)
      convim.api.scan_all_pages({
        callback = function(pages, err)
          if err then
            vim.notify('Scan failed: ' .. err, vim.log.levels.ERROR)
            return
          end
          M.set_cache(pages, os.date('%Y-%m-%d %H:%M:%S'))
          cleanup_old_search_cache()
          vim.notify('Confluence scan complete: ' .. #pages .. ' page(s) indexed', vim.log.levels.INFO)
          M.search_pages(nil)
        end,
      })
      return
    end
    
    local on_pick = function(page) M.edit_page(page.id) end

    -- Prefer telescope picker; fall back to vim.ui.select
    if picker.list_pages(cached_pages, 'Confluence pages', on_pick) then
      return
    end

    if #cached_pages == 0 then
      vim.notify('No pages in Confluence space(s)', vim.log.levels.INFO)
      return
    end

    vim.ui.select(cached_pages, {
      prompt = 'All Confluence pages (cached: ' .. (cache_timestamp or 'unknown') .. '):',
      format_item = function(page)
        local space = page._space_key and ('[' .. page._space_key .. '] ') or ''
        return space .. (page.title or page.id)
      end,
    }, function(page)
      if page then on_pick(page) end
    end)
    return
  end

  -- If query is provided, search/filter the cached pages
  local filtered_pages = {}
  for _, page in ipairs(cached_pages or {}) do
    local title = page.title or ''
    if title:lower():find(query:lower()) then
      table.insert(filtered_pages, page)
    end
  end

  -- If no cache yet or query not found in cache, try API search with caching
  if #filtered_pages == 0 and cached_pages ~= nil then
    local cached_results = get_cached_search_results(query, config.space_key)
    
    if cached_results then
      vim.notify('Using cached results for "' .. query .. '"', vim.log.levels.INFO)
      filtered_pages = cached_results
    else
      vim.notify('Searching Confluence for "' .. query .. '"...', vim.log.levels.INFO)
      convim.api.search_pages(query, config.space_key, {
        callback = function(results, err)
          if err then
            vim.notify('Search failed: ' .. err, vim.log.levels.ERROR)
            return
          end
          
          cache_search_results(query, config.space_key, results)
          cleanup_old_search_cache()
          
          if #results == 0 then
            vim.notify('No pages found matching: ' .. query, vim.log.levels.WARN)
            return
          end
          
          vim.notify('Found ' .. #results .. ' page(s) matching "' .. query .. '"', vim.log.levels.INFO)
          
          local on_pick = function(page) M.edit_page(page.id) end
          
          if picker.list_pages(results, 'Search results', on_pick) then
            return
          end

          vim.ui.select(results, {
            prompt = 'Search results:',
            format_item = function(page)
              local space = page._space_key and ('[' .. page._space_key .. '] ') or ''
              return space .. (page.title or page.id)
            end,
          }, function(page)
            if page then on_pick(page) end
          end)
        end,
      })
      return
    end
  end

  -- Show filtered results from cache
  local on_pick = function(page) M.edit_page(page.id) end
  
  if #filtered_pages == 0 then
    vim.notify('No pages found matching: ' .. query, vim.log.levels.WARN)
    return
  end

  if picker.list_pages(filtered_pages, 'Search results', on_pick) then
    return
  end

  vim.ui.select(filtered_pages, {
    prompt = 'Search results:',
    format_item = function(page)
      local space = page._space_key and ('[' .. page._space_key .. '] ') or ''
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

  -- Diagnostic: surface why a buffer would end up empty rather than silently
  -- handing the user a blank screen.  Common causes: API returned a body
  -- shape we don't expect (representation mismatch, permissions, deleted
  -- page) or the page genuinely has no body.
  if storage_value == '' then
    local has_body = page.body ~= nil
    local has_storage = has_body and page.body.storage ~= nil
    vim.notify(string.format(
      'convim: page %s came back with empty storage body ' ..
      '(body=%s, body.storage=%s, body.storage.value=%s). ' ..
      'Check :ConfluenceListSpaces auth and that the page has content.',
      page_id, tostring(has_body), tostring(has_storage),
      tostring(page.body and page.body.storage and page.body.storage.value)
    ), vim.log.levels.WARN)
  end

  -- Default editing mode: convert storage XHTML → markdown for a readable
  -- buffer, stashing the verbatim original (and any unmodelled macros) in
  -- a buffer-var so save can rebuild faithful storage XHTML.
  local md, meta = markdown.from_storage(storage_value)
  local lines = vim.split(md, '\n', { plain = true })
  return open_confluence_buf(page_id, title, lines, { mode = 'markdown', meta = meta })
end

--- Open a page in raw storage-XHTML mode (no markdown round-trip).  Useful as
--- an escape hatch when the markdown view loses fidelity for a particular
--- page; what you see is exactly what you save.
M.edit_page_raw = function(page_id)
  local err = config.validate()
  if err then vim.notify(err, vim.log.levels.ERROR) return end

  local page, fetch_err = api.get_page_content(page_id)
  if not page then
    vim.notify('Failed to fetch page: ' .. (fetch_err or ''), vim.log.levels.ERROR)
    return
  end

  local title = page.title or 'Untitled'
  local storage_value = (page.body and page.body.storage and page.body.storage.value) or ''
  local pretty = format.pretty(storage_value)
  local lines = vim.split(pretty, '\n', { plain = true })
  return open_confluence_buf(page_id, title, lines, { mode = 'storage' })
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
  -- New pages start in markdown mode with an empty body and an empty meta
  -- table — there are no original macros to preserve.
  return open_confluence_buf(page.id, title, { '' },
    { mode = 'markdown', meta = { original = '', macros = {} } })
end

M.save_page = function()
  local buf = vim.api.nvim_get_current_buf()
  local page_id = buf_get_var(buf, 'confluence_page_id')

  if not page_id then
    vim.notify('Not a Confluence buffer', vim.log.levels.WARN)
    return
  end

  local title = buf_get_var(buf, 'confluence_title') or 'Untitled'
  local mode  = buf_get_var(buf, 'confluence_mode') or 'storage'
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local body  = table.concat(lines, '\n')

  local content
  if mode == 'markdown' then
    local meta = buf_get_var(buf, 'confluence_meta') or { macros = {} }
    content = markdown.to_storage(body, meta)
    -- Surface a warning if the converter produced an empty document but the
    -- buffer wasn't empty — that means our regex pipeline missed something
    -- and we'd otherwise silently wipe the page.
    if vim.trim(body) ~= '' and (not content or content == '') then
      vim.notify(
        'convim: markdown→storage produced an empty body. ' ..
        'Aborting save to avoid wiping the page. Use :ConfluenceEditRaw <id> ' ..
        'to edit storage XHTML directly.',
        vim.log.levels.ERROR)
      return
    end
  else
    -- Re-compact the pretty-printed buffer back to a single-line storage string
    -- before sending to Confluence.
    content = format.compact(body)
  end

  local ok, update_err = api.update_page(page_id, title, content)
  if ok then
    vim.bo[buf].modified = false
    vim.notify('Saved: ' .. title, vim.log.levels.INFO)
  else
    vim.notify('Save failed: ' .. (update_err or ''), vim.log.levels.ERROR)
  end
end

return M
