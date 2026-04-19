local M = {}

local health = vim.health or require('health')
local start  = health.start  or health.report_start
local ok     = health.ok     or health.report_ok
local warn   = health.warn   or health.report_warn
local err    = health.error  or health.report_error
local info   = health.info   or health.report_info

M.check = function()
  start('convim')

  -- Neovim version
  if vim.fn.has('nvim-0.9') == 1 then
    ok('Neovim ≥ 0.9')
  else
    err('convim requires Neovim 0.9 or newer')
  end

  -- plenary.curl
  local has_curl, _ = pcall(require, 'plenary.curl')
  if has_curl then
    ok('plenary.curl is available')
  else
    err('plenary.curl not found',
      { 'Install nvim-lua/plenary.nvim' })
  end

  -- curl binary (plenary.curl shells out)
  if vim.fn.executable('curl') == 1 then
    ok('curl binary found in PATH')
  else
    err('curl is not in PATH',
      { 'plenary.curl needs the system curl(1) binary' })
  end

  -- Configuration
  local config = require('convim.config')
  local cfg_err = config.validate()
  if cfg_err then
    err(cfg_err)
  else
    ok('base_url: ' .. config.base_url)
    info('auth: ' .. (config.auth or
      (config.base_url:lower():find('atlassian%.net') and 'basic (auto)' or 'bearer (auto)')))
    if config.space_key then
      info('default space_key: ' .. config.space_key)
    else
      warn('no default space_key set; run :ConfluenceListSpaces to pick one')
    end

    -- Live auth probe
    local api = require('convim.api')
    local result = api.verify_auth()
    if result.ok then
      ok(result.message)
    else
      err('Auth check failed: ' .. (result.message or 'unknown'))
    end
  end
end

return M
