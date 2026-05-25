local lane = require("buddy.triggers.lane")

local M = {}

local MAX_TODO_SCAN_LINES = 5000

local PARAMS = {
	base = 0.5,
	decay_factor = 0.5,
	decay_unit = 90 * 1000,
	mass_ceiling = 18,
	arming_mass = 3,
	threshold_base = 7,
	jitter = 1,
	quiet_window = 6000,
	hold_ratio = 0.85,
}

local TODO_MASS = 0.75
local SAVE_THRESHOLD_NUDGE = 1

local function stable_hash(value)
	return vim.fn.sha256(value or "")
end

local function collect_todo_signatures(bufnr, debug)
	local signatures = {}

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return signatures
	end

	if vim.bo[bufnr].buftype ~= "" then
		return signatures
	end

	if vim.api.nvim_buf_line_count(bufnr) > MAX_TODO_SCAN_LINES then
		if debug then
			debug("skipped TODO scan for large buffer")
		end

		return signatures
	end

	for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		local trimmed = vim.trim(line)

		for _, marker in ipairs({ "TODO", "FIXME", "HACK" }) do
			if line:find(marker, 1, true) then
				signatures[marker .. "\0" .. stable_hash(trimmed)] = true
			end
		end
	end

	return signatures
end

local function count_new_todo_markers(buffer_state, next_signatures)
	local previous = buffer_state.todo_signatures or {}
	local count = 0

	for signature in pairs(next_signatures) do
		if not previous[signature] then
			count = count + 1
		end
	end

	return count
end

function M.new(opts)
	opts = opts or {}

	return {
		lane = lane.new(vim.tbl_extend("force", PARAMS, opts)),
		buffers = {},
		last_status = nil,
		save_nudged = false,
	}
end

function M.for_buffer(progress, bufnr, debug)
	if not progress.buffers[bufnr] then
		progress.buffers[bufnr] = {
			line_count = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_line_count(bufnr) or 0,
			todo_signatures = collect_todo_signatures(bufnr, debug),
		}
	end

	return progress.buffers[bufnr]
end

function M.on_text_changed(progress, bufnr, now, debug)
	local buffer_state = M.for_buffer(progress, bufnr, debug)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local next_signatures = collect_todo_signatures(bufnr, debug)
	local new_todos = count_new_todo_markers(buffer_state, next_signatures)
	local lines_delta = line_count - buffer_state.line_count
	local signal_mass = PARAMS.base + math.sqrt(math.abs(lines_delta))

	if new_todos > 0 then
		signal_mass = signal_mass + new_todos * TODO_MASS
	end

	local status = progress.lane:poll(now, { mass = signal_mass })

	buffer_state.line_count = line_count
	buffer_state.todo_signatures = next_signatures
	progress.last_status = status
	progress.save_nudged = false

	if new_todos > 0 and debug then
		debug("new TODO/FIXME/HACK marker added passive progress mass=" .. tostring(signal_mass))
	end

	if debug then
		debug("progress text signal lines_delta=" .. tostring(lines_delta) .. " status=" .. status)
	end

	return status, lines_delta
end

function M.on_buffer_saved(progress, now, debug)
	local changed = false

	if not progress.save_nudged then
		changed = progress.lane:lower_threshold(SAVE_THRESHOLD_NUDGE)
		progress.save_nudged = changed
	end

	local status = progress.lane:poll(now)
	progress.last_status = status

	if debug then
		debug("BufWritePost progress_nudge=" .. tostring(changed) .. " status=" .. tostring(status))
	end

	return status
end

function M.snapshot(progress)
	return {
		lane = progress.lane:get_state(),
		last_status = progress.last_status,
		save_nudged = progress.save_nudged,
		buffers = vim.deepcopy(progress.buffers),
	}
end

return M
