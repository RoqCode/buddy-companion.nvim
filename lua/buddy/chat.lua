local session = require("buddy.session")
local context = require("buddy.context")
local backend = require("buddy.backend")

local M = {}

local uv = vim.uv or vim.loop

local state = {
  chat_buf = nil,
  chat_win = nil,
  input_buf = nil,
  input_win = nil,
  pending = false,
  spinner_timer = nil,
  spinner_index = 1,
  closing = false,
}

local SPINNER_FRAMES = { "-", "\\", "|", "/" }
local stop_spinner

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buffer(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function close_window(win)
  if is_valid_window(win) then
    vim.api.nvim_win_close(win, true)
  end
end

local function close_chat_windows()
  if state.closing then
    return
  end

  state.closing = true
  stop_spinner()
  close_window(state.input_win)
  close_window(state.chat_win)
  state.input_win = nil
  state.chat_win = nil
  state.closing = false
end

local function map_close(buf)
  vim.keymap.set("n", "q", close_chat_windows, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close_chat_windows, { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-w>q", close_chat_windows, { buffer = buf, silent = true })
  vim.keymap.set("n", "<C-w><C-q>", close_chat_windows, { buffer = buf, silent = true })
end

local function ensure_chat_buffer()
  if is_valid_buffer(state.chat_buf) then
    return state.chat_buf
  end

  state.chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.chat_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.chat_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.chat_buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.chat_buf })
  vim.api.nvim_buf_set_name(state.chat_buf, "Buddy Chat")
  map_close(state.chat_buf)

  return state.chat_buf
end

local function ensure_input_buffer()
  if is_valid_buffer(state.input_buf) then
    return state.input_buf
  end

  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.input_buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.input_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.input_buf })
  vim.api.nvim_buf_set_name(state.input_buf, "Buddy Input")
  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    M.submit_input()
  end, { buffer = state.input_buf, silent = true })
  map_close(state.input_buf)
  vim.keymap.set("i", "<Esc>", close_chat_windows, { buffer = state.input_buf, silent = true })

  return state.input_buf
end

local function register_window_closed_autocmd()
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("BuddyChatWindow", { clear = true }),
    callback = function(event)
      if state.closing then
        return
      end

      local closed_win = tonumber(event.match)

      if closed_win == state.chat_win or closed_win == state.input_win then
        close_chat_windows()
      end
    end,
  })
end

local function configure_window(win)
  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("linebreak", true, { win = win })
  vim.api.nvim_set_option_value("breakindent", true, { win = win })
end

local function input_title()
  if not state.pending then
    return " Ask Buddy "
  end

  return " Buddy thinking " .. SPINNER_FRAMES[state.spinner_index] .. " "
end

local function render_input_title()
  if not is_valid_window(state.input_win) then
    return
  end

  vim.api.nvim_win_set_config(state.input_win, {
    title = input_title(),
    title_pos = "left",
  })
end

stop_spinner = function()
  if state.spinner_timer then
    state.spinner_timer:stop()
    state.spinner_timer:close()
    state.spinner_timer = nil
  end
end

local function set_pending(pending)
  state.pending = pending

  if not pending then
    stop_spinner()
    state.spinner_index = 1
    render_input_title()
    return
  end

  render_input_title()

  if state.spinner_timer then
    return
  end

  state.spinner_timer = uv.new_timer()
  state.spinner_timer:start(120, 120, vim.schedule_wrap(function()
    if not state.pending then
      return
    end

    state.spinner_index = (state.spinner_index % #SPINNER_FRAMES) + 1
    render_input_title()
  end))
end

local function restart_spinner_if_pending()
  if state.pending and not state.spinner_timer then
    set_pending(true)
  end
end

local function clear_input()
  if not is_valid_buffer(state.input_buf) then
    return
  end

  vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

  if is_valid_window(state.input_win) then
    vim.api.nvim_win_set_cursor(state.input_win, { 1, 0 })
  end
end

local function focus_input()
  if not is_valid_window(state.input_win) then
    return
  end

  vim.api.nvim_set_current_win(state.input_win)
  vim.api.nvim_win_set_cursor(state.input_win, { 1, 0 })
  vim.cmd("startinsert")
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

local function submit_question(question)
  question = question and vim.trim(question) or ""

  if question == "" then
    return
  end

  if state.pending then
    vim.notify("Buddy is already thinking", vim.log.levels.INFO)
    return
  end

  local request_started_at = session.current().started_at

  session.append_message("user", question)
  clear_input()
  set_pending(true)

  context.collect_async(function(collected_context)
    if not session.current().active or session.current().started_at ~= request_started_at then
      set_pending(false)
      return
    end

    if not collected_context then
      set_pending(false)
      return
    end

    backend.answer_async(collected_context, question, function(response, err)
      if not session.current().active or session.current().started_at ~= request_started_at then
        set_pending(false)
        return
      end

      set_pending(false)

      if err then
        session.report_backend_error("OpenCode backend error: " .. err)
        return
      end

      session.append_message("buddy", response.message, {
        reason = "user_question",
      })
    end)
  end)
end

function M.render()
  if not is_valid_buffer(state.chat_buf) then
    return
  end

  local current_session = session.current()
  local lines = {}

  if not current_session.active then
    lines = { "Buddy is not running. Start a session with :BuddyStart." }
  elseif #current_session.messages == 0 then
    lines = { "Buddy session is active.", "", "No messages yet." }
  else
    for _, message in ipairs(current_session.messages) do
      vim.list_extend(lines, message_lines(message))
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.chat_buf })
  vim.api.nvim_buf_set_lines(state.chat_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.chat_buf })

  if is_valid_window(state.chat_win) then
    local last_line = math.max(1, vim.api.nvim_buf_line_count(state.chat_buf))
    vim.api.nvim_win_set_cursor(state.chat_win, { last_line, 0 })
  end
end

function M.open()
  local chat_buf = ensure_chat_buffer()
  local input_buf = ensure_input_buffer()

  if is_valid_window(state.chat_win) and is_valid_window(state.input_win) then
    configure_window(state.chat_win)
    render_input_title()
    restart_spinner_if_pending()
    M.render()
    focus_input()
    return
  end

  local width = math.min(80, math.max(40, vim.o.columns - 8))
  local total_height = math.min(22, math.max(10, vim.o.lines - 6))
  local chat_height = total_height - 5
  local input_height = 1
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  state.chat_win = vim.api.nvim_open_win(chat_buf, false, {
    relative = "editor",
    width = width,
    height = chat_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Buddy Chat ",
    title_pos = "center",
  })

  state.input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = input_height,
    row = row + chat_height + 2,
    col = col,
    style = "minimal",
    border = "rounded",
    title = input_title(),
    title_pos = "left",
  })

  configure_window(state.chat_win)
  vim.api.nvim_set_option_value("wrap", false, { win = state.input_win })
  register_window_closed_autocmd()
  restart_spinner_if_pending()
  M.render()
  focus_input()
end

function M.close()
  close_chat_windows()
end

function M.submit_input()
  if not session.current().active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  local buf = ensure_input_buffer()
  local last_line_number = vim.api.nvim_buf_line_count(buf)
  local line = vim.api.nvim_buf_get_lines(buf, last_line_number - 1, last_line_number, false)[1] or ""

  submit_question(line)
end

function M.ask()
  if not session.current().active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  vim.ui.input({ prompt = "Ask Buddy: " }, function(question)
    submit_question(question)
  end)
end

return M
