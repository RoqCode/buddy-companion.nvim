local session = require("buddy.session")
local context = require("buddy.context")
local backend = require("buddy.backend")

local M = {}

local state = {
  buf = nil,
  win = nil,
}

local PROMPT_PREFIX = "> "

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buffer(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function ensure_buffer()
  if is_valid_buffer(state.buf) then
    return state.buf
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = state.buf })
  vim.api.nvim_buf_set_name(state.buf, "Buddy Chat")
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    M.submit_input()
  end, { buffer = state.buf, silent = true })

  return state.buf
end

local function configure_window(win)
  vim.api.nvim_set_option_value("wrap", true, { win = win })
  vim.api.nvim_set_option_value("linebreak", true, { win = win })
  vim.api.nvim_set_option_value("breakindent", true, { win = win })
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

  session.append_message("user", question)

  context.collect_async(function(collected_context)
    if not collected_context then
      return
    end

    backend.answer_async(collected_context, question, function(response, err)
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
  if not is_valid_buffer(state.buf) then
    return
  end

  local current_session = session.current()
  local lines = {}

  if not current_session.active then
    lines = { "Buddy is not running. Start a session with :BuddyStart." }
  elseif #current_session.messages == 0 then
    lines = { "Buddy session is active.", "", "No messages yet.", "", PROMPT_PREFIX }
  else
    for _, message in ipairs(current_session.messages) do
      vim.list_extend(lines, message_lines(message))
    end

    table.insert(lines, PROMPT_PREFIX)
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf })
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  if is_valid_window(state.win) then
    local last_line = math.max(1, vim.api.nvim_buf_line_count(state.buf))
    vim.api.nvim_win_set_cursor(state.win, { last_line, #PROMPT_PREFIX })
  end
end

function M.open()
  local buf = ensure_buffer()

  if is_valid_window(state.win) then
    vim.api.nvim_set_current_win(state.win)
    configure_window(state.win)
    M.render()
    return
  end

  local width = math.min(80, math.max(40, vim.o.columns - 8))
  local height = math.min(20, math.max(8, vim.o.lines - 6))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  state.win = vim.api.nvim_open_win(buf, true, {
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

  configure_window(state.win)
  M.render()
end

function M.submit_input()
  if not session.current().active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return
  end

  local buf = ensure_buffer()
  local last_line_number = vim.api.nvim_buf_line_count(buf)
  local line = vim.api.nvim_buf_get_lines(buf, last_line_number - 1, last_line_number, false)[1] or ""

  if line:sub(1, #PROMPT_PREFIX) ~= PROMPT_PREFIX then
    return
  end

  submit_question(line:sub(#PROMPT_PREFIX + 1))
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
