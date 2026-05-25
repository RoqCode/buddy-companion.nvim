local config = require("buddy.config")
local session = require("buddy.session")
local context = require("buddy.context")
local backend = require("buddy.backend")
local notification = require("buddy.notify")
local lane = require("buddy.triggers.lane")

local M = {}

local uv = vim.uv or vim.loop

local group = nil
local state = {
	active = false,
	generation = nil,
	debounce_timer = nil,
	pending_reason = nil,
	pending_bufnr = nil,
	last_prompt_at = nil,
	proactive_calls = 0,
	diagnostic_signatures = {},
	progress = nil,
	running = false,
}

local MAX_TODO_SCAN_LINES = 5000
local schedule

local PROGRESS_PARAMS = {
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

local TODO_PROGRESS_MASS = 0.75
local SAVE_THRESHOLD_NUDGE = 1

local IMPORTANT_DIAGNOSTICS = {
	[vim.diagnostic.severity.ERROR] = true,
	[vim.diagnostic.severity.WARN] = true,
}

local function debug(message)
	local trigger_config = config.get().triggers or {}

	if trigger_config.debug then
		vim.notify("Buddy trigger: " .. message, vim.log.levels.DEBUG)
	end
end

local function stable_hash(value)
	return vim.fn.sha256(value or "")
end

local function create_progress_state()
	return {
		lane = lane.new(PROGRESS_PARAMS),
		buffers = {},
		last_status = nil,
		save_nudged = false,
	}
end

local function current_generation()
	return session.current().generation
end

local function reset_state()
	if state.debounce_timer then
		state.debounce_timer:stop()
		state.debounce_timer:close()
	end

	state.active = false
	state.generation = nil
	state.debounce_timer = nil
	state.pending_reason = nil
	state.pending_bufnr = nil
	state.last_prompt_at = nil
	state.proactive_calls = 0
	state.diagnostic_signatures = {}
	state.progress = create_progress_state()
	state.running = false
end

local function diagnostic_signature(diagnostic)
	local path = vim.api.nvim_buf_get_name(diagnostic.bufnr or 0)

	return table.concat({
		path,
		tostring(diagnostic.lnum),
		tostring(diagnostic.col),
		tostring(diagnostic.severity),
		diagnostic.source or "",
		diagnostic.message or "",
	}, "\0")
end

local function collect_diagnostic_signatures()
	local signatures = {}

	for _, diagnostic in ipairs(vim.diagnostic.get()) do
		if IMPORTANT_DIAGNOSTICS[diagnostic.severity] then
			signatures[diagnostic_signature(diagnostic)] = true
		end
	end

	return signatures
end

local function has_new_diagnostics(next_signatures)
	for signature in pairs(next_signatures) do
		if not state.diagnostic_signatures[signature] then
			return true
		end
	end

	return false
end

local function collect_todo_signatures(bufnr)
	local signatures = {}

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return signatures
	end

	if vim.bo[bufnr].buftype ~= "" then
		return signatures
	end

	if vim.api.nvim_buf_line_count(bufnr) > MAX_TODO_SCAN_LINES then
		debug("skipped TODO scan for large buffer")
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

local function count_new_todo_markers(bufnr, next_signatures)
	local progress = state.progress or create_progress_state()
	local previous = (progress.buffers[bufnr] and progress.buffers[bufnr].todo_signatures) or {}
	local count = 0

	for signature in pairs(next_signatures) do
		if not previous[signature] then
			count = count + 1
		end
	end

	return count
end

local function can_call_backend()
	local current_config = config.get()
	local trigger_config = current_config.triggers or {}
	local cooldown_ms = trigger_config.cooldown_ms
	local max_proactive_calls = trigger_config.max_proactive_calls

	if type(max_proactive_calls) == "number" and state.proactive_calls >= max_proactive_calls then
		debug("blocked by max_proactive_calls")
		return false
	end

	if type(cooldown_ms) == "number" and state.last_prompt_at then
		local elapsed_ms = uv.now() - state.last_prompt_at

		if elapsed_ms < cooldown_ms then
			debug("blocked by cooldown")
			return false
		end
	end

	return true
end

local function instruction_for(reason)
	return table.concat({
		"Proactive Buddy check triggered by " .. reason .. ".",
		"Use the provided context to decide whether there is one concrete, useful thing to tell the user.",
		"Return outcome=\"silent_reset\" if the observation is generic, speculative, repeated, or not actionable.",
		"Return outcome=\"silent_hold\" only if a useful observation may be forming but is not ready yet.",
	}, "\n")
end

local function append_backend_error(err)
	session.report_backend_error("OpenCode backend error: " .. err)
end

local function finish_backend_check()
	state.running = false

	if state.pending_reason then
		debug("replaying pending trigger after backend check")
		schedule(state.pending_reason, state.pending_bufnr)
	end
end

local function run_backend_check(reason, bufnr)
	if state.running then
		state.pending_reason = reason
		state.pending_bufnr = bufnr
		debug("kept " .. reason .. " pending because a proactive check is already running")
		return
	end

	if not can_call_backend() then
		return
	end

	local generation = state.generation
	state.running = true
	state.last_prompt_at = uv.now()
	state.proactive_calls = state.proactive_calls + 1
	debug("backend check started for " .. reason)

	context.collect_async(function(collected_context)
		if not session.current().active or current_generation() ~= generation then
			finish_backend_check()
			debug("backend check ignored because session changed")
			return
		end

		if not collected_context then
			finish_backend_check()
			debug("backend check stopped because context collection returned nothing")
			return
		end

		backend.prompt_async(collected_context, instruction_for(reason), function(response, err)
			if not session.current().active or current_generation() ~= generation then
				finish_backend_check()
				debug("backend response ignored because session changed")
				return
			end

			finish_backend_check()

			if err then
				debug("backend check failed: " .. err)
				append_backend_error(err)
				return
			end

			debug("backend response outcome=" .. tostring(response.outcome))

			if response.outcome == "speak" then
				local appended = session.append_message("buddy", response.message, {
					severity = response.severity,
					reason = response.reason,
					trigger = reason,
					bufnr = bufnr,
					proactive = true,
				})

				if appended then
					notification.show(response.message, response.severity)
				end
			end
		end)
	end, { source_buf = bufnr })
end

local function evaluate_pending_trigger()
	local reason = state.pending_reason
	local bufnr = state.pending_bufnr

	state.pending_reason = nil
	state.pending_bufnr = nil

	if not reason or not session.current().active or current_generation() ~= state.generation then
		debug("debounced trigger ignored")
		return
	end

	debug("debounced trigger evaluating " .. reason)

	if state.running then
		state.pending_reason = reason
		state.pending_bufnr = bufnr
		debug("kept " .. reason .. " pending because a proactive check is already running")
		return
	end

	run_backend_check(reason, bufnr)
end

function schedule(reason, bufnr)
	if not session.current().active or current_generation() ~= state.generation then
		return
	end

	local current_config = config.get()
	local trigger_config = current_config.triggers or {}
	local debounce_ms = trigger_config.debounce_ms or 2000

	state.pending_reason = reason
	state.pending_bufnr = bufnr
	debug("scheduled " .. reason .. " with debounce " .. tostring(debounce_ms) .. "ms")

	if not state.debounce_timer then
		state.debounce_timer = uv.new_timer()
	end

	state.debounce_timer:stop()
	state.debounce_timer:start(debounce_ms, 0, vim.schedule_wrap(evaluate_pending_trigger))
end

local function on_diagnostics_changed(bufnr)
	local next_signatures = collect_diagnostic_signatures()
	local changed = has_new_diagnostics(next_signatures)

	state.diagnostic_signatures = next_signatures

	if changed then
		debug("new diagnostic detected")
		schedule("diagnostic_changed", bufnr or vim.api.nvim_get_current_buf())
	else
		debug("diagnostic event without new WARN/ERROR")
	end
end

local function progress_for_buffer(bufnr)
	local progress = state.progress

	if not progress then
		progress = create_progress_state()
		state.progress = progress
	end

	if not progress.buffers[bufnr] then
		progress.buffers[bufnr] = {
			line_count = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_line_count(bufnr) or 0,
			todo_signatures = collect_todo_signatures(bufnr),
		}
	end

	return progress, progress.buffers[bufnr]
end

local function poll_progress(now, signal)
	local progress = state.progress

	if not progress then
		return nil
	end

	local status = progress.lane:poll(now, signal)
	progress.last_status = status
	debug("progress status=" .. status .. " mass=" .. string.format("%.2f", progress.lane.mass))
	return status
end

local function on_text_changed()
	local bufnr = vim.api.nvim_get_current_buf()

	if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
		return
	end

	local progress, buffer_state = progress_for_buffer(bufnr)
	local now = uv.now()
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local next_signatures = collect_todo_signatures(bufnr)
	local new_todos = count_new_todo_markers(bufnr, next_signatures)
	local lines_delta = line_count - buffer_state.line_count
	local signal_mass = PROGRESS_PARAMS.base + math.sqrt(math.abs(lines_delta))

	if new_todos > 0 then
		signal_mass = signal_mass + new_todos * TODO_PROGRESS_MASS
	end

	local status = progress.lane:poll(now, {
		mass = signal_mass,
	})

	buffer_state.line_count = line_count
	buffer_state.todo_signatures = next_signatures
	progress.last_status = status
	progress.save_nudged = false

	if new_todos > 0 then
		debug("new TODO/FIXME/HACK marker added passive progress mass=" .. tostring(signal_mass))
	end

	debug("progress text signal lines_delta=" .. tostring(lines_delta) .. " status=" .. status)
end

local function on_buffer_saved(bufnr)
	local progress = state.progress

	if not progress then
		return
	end

	local changed = false

	if not progress.save_nudged then
		changed = progress.lane:lower_threshold(SAVE_THRESHOLD_NUDGE)
		progress.save_nudged = changed
	end

	local status = poll_progress(uv.now())

	debug("BufWritePost progress_nudge=" .. tostring(changed) .. " status=" .. tostring(status))
end

local function prime_baselines()
	state.diagnostic_signatures = collect_diagnostic_signatures()

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			progress_for_buffer(bufnr)
		end
	end
end

function M.start()
	reset_state()

	if not session.current().active then
		return
	end

	state.active = true
	state.generation = current_generation()
	debug("started")
	group = vim.api.nvim_create_augroup("BuddyTriggers", { clear = true })

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(event)
			on_buffer_saved(event.buf)
		end,
	})

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = function(event)
			on_diagnostics_changed(event.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group,
		callback = on_text_changed,
	})

	prime_baselines()
end

function M.stop()
	debug("stopped")

	if group then
		vim.api.nvim_del_augroup_by_id(group)
		group = nil
	end

	reset_state()
end

function M.get_state()
	local snapshot = {
		active = state.active,
		generation = state.generation,
		debounce_timer = state.debounce_timer,
		pending_reason = state.pending_reason,
		pending_bufnr = state.pending_bufnr,
		last_prompt_at = state.last_prompt_at,
		proactive_calls = state.proactive_calls,
		diagnostic_signatures = vim.deepcopy(state.diagnostic_signatures),
		running = state.running,
	}

	if state.progress then
		snapshot.progress = {
			lane = state.progress.lane:get_state(),
			last_status = state.progress.last_status,
			save_nudged = state.progress.save_nudged,
			buffers = vim.deepcopy(state.progress.buffers),
		}
	end

	return snapshot
end

return M
