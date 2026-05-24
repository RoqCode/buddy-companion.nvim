local M = {}

local defaults = {
  additional_context = ".local",
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get_config()
  return vim.deepcopy(config)
end

return M
