local M = {}

M.setup = function(opts)
  require('convim.config').setup(opts or {})
end

-- Expose submodules lazily so callers can do convim.ui.xxx / convim.api.xxx
setmetatable(M, {
  __index = function(_, key)
    local ok, mod = pcall(require, 'convim.' .. key)
    if ok then return mod end
  end,
})

return M
