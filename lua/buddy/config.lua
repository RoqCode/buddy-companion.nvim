local M = {}

local defaults = {
  additional_context = ".local",
  opencode = {
    base_url = "http://127.0.0.1:4096",
    agent = "buddy",
    timeout_ms = 30000,
  },
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return vim.deepcopy(config)
end

return M
