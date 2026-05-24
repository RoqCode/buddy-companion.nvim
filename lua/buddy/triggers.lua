local config = require("buddy.config")
local session = require("buddy.session")
local context = require("buddy.context")
local backend = require("buddy.backend")

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
	diff_hash = nil,
	diagnostic_signatures = {},
	todo_signatures = {},
	running = false,
}

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
	state.diff_hash = nil
	state.diagnostic_signatures = {}
	state.todo_signatures = {}
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

	for line_number, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
		for _, marker in ipairs({ "TODO", "FIXME", "HACK" }) do
			if line:find(marker, 1, true) then
				signatures[line_number .. "\0" .. marker] = true
			end
		end
	end

	return signatures
end

local function has_new_todo_marker(bufnr, next_signatures)
	local previous = state.todo_signatures[bufnr] or {}

	for signature in pairs(next_signatures) do
		if not previous[signature] then
			return true
		end
	end

	return false
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
		"Prefer should_speak=false if the observation is generic, speculative, repeated, or not actionable.",
	}, "\n")
end

local function append_backend_error(err)
	session.report_backend_error("OpenCode backend error: " .. err)
end

local function run_backend_check(reason, bufnr)
	if state.running then
		debug("ignored " .. reason .. " because a proactive check is already running")
		return
	end

	if not can_call_backend() then
		return
	end

	local generation = state.generation
	local source_win = vim.api.nvim_get_current_win()

	state.running = true
	state.last_prompt_at = uv.now()
	state.proactive_calls = state.proactive_calls + 1
	debug("backend check started for " .. reason)

	context.collect_async(function(collected_context)
		if not session.current().active or current_generation() ~= generation then
			state.running = false
			debug("backend check ignored because session changed")
			return
		end

		if not collected_context then
			state.running = false
			debug("backend check stopped because context collection returned nothing")
			return
		end

		backend.prompt_async(collected_context, instruction_for(reason), function(response, err)
			if not session.current().active or current_generation() ~= generation then
				state.running = false
				debug("backend response ignored because session changed")
				return
			end

			state.running = false

			if err then
				debug("backend check failed: " .. err)
				append_backend_error(err)
				return
			end

			debug("backend response should_speak=" .. tostring(response.should_speak))

			if response.should_speak then
				session.append_message("buddy", response.message, {
					severity = response.severity,
					reason = response.reason,
					trigger = reason,
					bufnr = bufnr,
				})
			end
		end)
	end, { source_win = source_win })
end

local function update_diff_baseline(callback)
	local generation = state.generation

	context.collect_async(function(collected_context)
		if not session.current().active or current_generation() ~= generation then
			debug("diff baseline skipped because session changed")
			callback(false)
			return
		end

		if not collected_context or not collected_context.git_diff or not collected_context.git_diff.available then
			debug("diff baseline unavailable")
			callback(false)
			return
		end

		local next_hash = stable_hash(collected_context.git_diff.content)
		local changed = state.diff_hash ~= nil and state.diff_hash ~= next_hash

		state.diff_hash = next_hash
		debug("diff baseline updated changed=" .. tostring(changed))
		callback(changed)
	end)
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

	if reason == "diff_changed" then
		update_diff_baseline(function(changed)
			if changed then
				run_backend_check(reason, bufnr)
			else
				debug("diff unchanged after debounce")
			end
		end)
		return
	end

	run_backend_check(reason, bufnr)
end

local function schedule(reason, bufnr)
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

local function on_diagnostics_changed()
	local next_signatures = collect_diagnostic_signatures()
	local changed = has_new_diagnostics(next_signatures)

	state.diagnostic_signatures = next_signatures

	if changed then
		debug("new diagnostic detected")
		schedule("diagnostic_changed", vim.api.nvim_get_current_buf())
	else
		debug("diagnostic event without new WARN/ERROR")
	end
end

local function on_text_changed()
	local bufnr = vim.api.nvim_get_current_buf()
	local next_signatures = collect_todo_signatures(bufnr)
	local changed = has_new_todo_marker(bufnr, next_signatures)

	state.todo_signatures[bufnr] = next_signatures

	if changed then
		debug("new TODO/FIXME/HACK marker detected")
		schedule("todo_marker_added", bufnr)
	end
end

local function prime_baselines()
	state.diagnostic_signatures = collect_diagnostic_signatures()

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			state.todo_signatures[bufnr] = collect_todo_signatures(bufnr)
		end
	end

	update_diff_baseline(function() end)
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
			debug("BufWritePost")
			schedule("diff_changed", event.buf)
		end,
	})

	vim.api.nvim_create_autocmd("DiagnosticChanged", {
		group = group,
		callback = on_diagnostics_changed,
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
	return vim.deepcopy(state)
end

return M
