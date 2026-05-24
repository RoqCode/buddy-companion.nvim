local config = require("buddy.config")

local M = {}

local state = {
	win = nil,
	buf = nil,
}

local function is_valid_window(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function close_existing()
	if is_valid_window(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end

	state.win = nil
	state.buf = nil
end

local function truncate(value, limit)
	if #value <= limit then
		return value
	end

	return value:sub(1, math.max(0, limit - 3)) .. "..."
end

local function notification_text(message)
	local notification_config = config.get().notifications or {}
	local content = notification_config.floating_content or "full"

	if content == "hidden" or content == "none" then
		return "Buddy has a new message."
	end

	if content == "preview" or content == "partial" then
		local limit = notification_config.floating_preview_chars or 50
		return truncate(message, limit)
	end

	return message
end

local function display_height(lines, width)
	local height = 0

	for _, line in ipairs(lines) do
		height = height + math.max(1, math.ceil(#line / width))
	end

	return height
end

function M.show(message, severity)
	local notification_config = config.get().notifications or {}
	local duration_ms = notification_config.floating_duration_ms

	if type(duration_ms) ~= "number" then
		duration_ms = 5000
	end

	if duration_ms <= 0 then
		return
	end

	close_existing()

	local text = notification_text(message or "")
	local lines = vim.split(text, "\n", { plain = true })
	local width = math.min(80, math.max(24, vim.o.columns - 8))
	local height = math.min(display_height(lines, width), math.max(1, vim.o.lines - 6))
	local row = math.max(1, vim.o.lines - height - 4)
	local col = math.max(0, vim.o.columns - width - 4)

	state.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = state.buf })
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

	state.win = vim.api.nvim_open_win(state.buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		focusable = false,
		title = " Buddy ",
		title_pos = "left",
	})

	vim.api.nvim_set_option_value("wrap", true, { win = state.win })
	vim.api.nvim_set_option_value("linebreak", true, { win = state.win })

	local win = state.win

	vim.defer_fn(function()
		if state.win == win then
			close_existing()
		end
	end, duration_ms)
end

return M
