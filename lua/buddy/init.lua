local M = {}

local defaults = {
  additional_context = ".local",
}

local config = vim.deepcopy(defaults)
local session = {
  active = false,
  started_at = nil,
  workspace_root = nil,
  messages = {},
  backend_available = true,
}

local function current_working_directory()
  return vim.uv and vim.uv.cwd() or vim.loop.cwd()
end

local function find_workspace_root()
  local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()

  if result.code == 0 then
    return vim.trim(result.stdout)
  end

  return current_working_directory()
end

local function reset_session()
  session.active = false
  session.started_at = nil
  session.workspace_root = nil
  session.messages = {}
  session.backend_available = true
end

local function start_session()
  if session.active then
    vim.notify("Buddy session is already active", vim.log.levels.INFO)
    return
  end

  session.active = true
  session.started_at = os.time()
  session.workspace_root = find_workspace_root()
  session.messages = {}
  session.backend_available = true

  vim.notify("Buddy session started", vim.log.levels.INFO)
end

local function stop_session()
  if not session.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  reset_session()
  vim.notify("Buddy session stopped", vim.log.levels.INFO)
end

local function register_commands()
  vim.api.nvim_create_user_command("BuddyStart", start_session, { force = true })
  vim.api.nvim_create_user_command("BuddyStop", stop_session, { force = true })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  register_commands()
end

function M.get_config()
  return vim.deepcopy(config)
end

function M.get_session()
  return vim.deepcopy(session)
end

return M
