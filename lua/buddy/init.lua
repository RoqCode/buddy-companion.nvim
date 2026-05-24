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
local chat = {
  buf = nil,
  win = nil,
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

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buffer(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function ensure_chat_buffer()
  if is_valid_buffer(chat.buf) then
    return chat.buf
  end

  chat.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = chat.buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = chat.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = chat.buf })
  vim.api.nvim_buf_set_name(chat.buf, "Buddy Chat")

  return chat.buf
end

local function message_lines(message)
  local role = message.role or "buddy"
  local content = message.content or ""
  local lines = vim.split(content, "\n", { plain = true })

  if #lines == 0 then
    lines = { "" }
  end

  lines[1] = string.format("[%s] %s", role, lines[1])

  for index = 2, #lines do
    lines[index] = "  " .. lines[index]
  end

  table.insert(lines, "")

  return lines
end

local function render_chat()
  if not is_valid_buffer(chat.buf) then
    return
  end

  local lines = {}

  if not session.active then
    lines = { "Buddy is not running. Start a session with :BuddyStart." }
  elseif #session.messages == 0 then
    lines = { "Buddy session is active.", "", "No messages yet." }
  else
    for _, message in ipairs(session.messages) do
      vim.list_extend(lines, message_lines(message))
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = chat.buf })
  vim.api.nvim_buf_set_lines(chat.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = chat.buf })
end

local function open_chat()
  local buf = ensure_chat_buffer()

  if is_valid_window(chat.win) then
    vim.api.nvim_set_current_win(chat.win)
    render_chat()
    return
  end

  local width = math.min(80, math.max(40, vim.o.columns - 8))
  local height = math.min(20, math.max(8, vim.o.lines - 6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  chat.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Buddy Chat ",
    title_pos = "center",
  })

  render_chat()
end

local function append_message(role, content, meta)
  if not session.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return false
  end

  table.insert(session.messages, {
    role = role,
    content = content,
    meta = meta or {},
    created_at = os.time(),
  })

  render_chat()
  return true
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

  render_chat()
  vim.notify("Buddy session started", vim.log.levels.INFO)
end

local function stop_session()
  if not session.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  reset_session()
  render_chat()
  vim.notify("Buddy session stopped", vim.log.levels.INFO)
end

local function register_commands()
  vim.api.nvim_create_user_command("BuddyStart", start_session, { force = true })
  vim.api.nvim_create_user_command("BuddyStop", stop_session, { force = true })
  vim.api.nvim_create_user_command("BuddyChat", open_chat, { force = true })
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

function M._append_message(role, content, meta)
  return append_message(role, content, meta)
end

return M
