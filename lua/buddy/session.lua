local M = {}

local uv = vim.uv or vim.loop

local state = {
  active = false,
  generation = 0,
  started_at = nil,
  workspace_root = nil,
  messages = {},
  backend_available = true,
  backend_error_reported = false,
  opencode_session_id = nil,
}

local on_change = nil
local GIT_TIMEOUT_MS = 2000
local next_generation = 0

local function notify_change()
  if on_change then
    on_change()
  end
end

local function current_working_directory()
  return uv.cwd()
end

local function find_workspace_root()
  local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait(GIT_TIMEOUT_MS)

  if result and result.code == 0 then
    return vim.trim(result.stdout)
  end

  return current_working_directory()
end

local function reset()
  state.active = false
  state.generation = 0
  state.started_at = nil
  state.workspace_root = nil
  state.messages = {}
  state.backend_available = true
  state.backend_error_reported = false
  state.opencode_session_id = nil
end

function M.set_on_change(callback)
  on_change = callback
end

function M.start()
  if state.active then
    vim.notify("Buddy session is already active", vim.log.levels.INFO)
    return
  end

  state.active = true
  next_generation = next_generation + 1
  state.generation = next_generation
  state.started_at = os.time()
  state.workspace_root = find_workspace_root()
  state.messages = {}
  state.backend_available = true
  state.backend_error_reported = false
  state.opencode_session_id = nil

  notify_change()
  vim.notify("Buddy session started", vim.log.levels.INFO)
end

function M.stop()
  if not state.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  reset()
  notify_change()
  vim.notify("Buddy session stopped", vim.log.levels.INFO)
end

function M.append_message(role, content, meta)
  if not state.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return false
  end

  table.insert(state.messages, {
    role = role,
    content = content,
    meta = meta or {},
    created_at = os.time(),
  })

  notify_change()
  return true
end

function M.set_backend_available(available)
  state.backend_available = available

  if available then
    state.backend_error_reported = false
  end

  notify_change()
end

function M.report_backend_error(content)
  state.backend_available = false

  if state.backend_error_reported then
    notify_change()
    return false
  end

  state.backend_error_reported = true
  return M.append_message("system", content)
end

function M.set_opencode_session_id(session_id)
  state.opencode_session_id = session_id
  notify_change()
end

function M.get()
  return vim.deepcopy(state)
end

function M.current()
  return state
end

return M
