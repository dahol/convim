local M = {}

M.base_url = nil
M.token = nil
M.space_key = nil

--- Validate that the required configuration is present.
--- Returns an error string if invalid, or nil if OK.
M.validate = function()
  if not M.base_url or M.base_url == '' then
    return 'convim: base_url is not configured. Call require("convim").setup({base_url = ...})'
  end
  if not M.token or M.token == '' then
    return 'convim: token is not configured. Call require("convim").setup({token = ...})'
  end
  return nil
end

M.setup = function(opts)
  if opts.base_url then M.base_url = opts.base_url end
  if opts.token then M.token = opts.token end
  if opts.space_key then M.space_key = opts.space_key end
end

return M
