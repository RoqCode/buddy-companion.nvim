local config = require("buddy.config")
local session = require("buddy.session")
local context = require("buddy.context")
local backend = require("buddy.backend")
local notification = require("buddy.notify")
local budget = require("buddy.triggers.budget")
local arbiter = require("buddy.triggers.arbiter")
local progress_lane = require("buddy.triggers.progress")
local struggle_lane = require("buddy.triggers.struggle")
local self_check_lane = require("buddy.triggers.self_check")
local profiles = require("buddy.triggers.profile")
local instructions = require("buddy.triggers.instructions")

local M = {}

local uv = vim.uv or vim.loop

local group = nil
local state = {
	active = false,
	generation = nil,
	proactive_calls = 0,
	diagnostic_signatures = {},
	progress = nil,
	struggle = nil,
	self_check = nil,
	budget = nil,
	arbiter = nil,
	trigger_profile = nil,
	tick_timer = nil,
	last_dispatch_bufnr = nil,
	running = false,
}

local TICK_MS = 1500
local SILENCE_MS = 1500

local function resolve_trigger_profile()
	local trigger_config = config.get().triggers or {}
	return profiles.resolve(trigger_config)
end

local function debug(message)
	local trigger_config = config.get().triggers or {}

	if trigger_config.debug then
		vim.notify("Buddy trigger: " .. message, vim.log.levels.DEBUG)
	end
end

local function create_runtime()
	local profile = resolve_trigger_profile()
	local progress = progress_lane.new(profile.progress)
	local struggle = struggle_lane.new(profile.struggle)
	local self_check = self_check_lane.new(profile.self_check)
	local attention_budget = budget.new(profile.budget)

	return progress, struggle, self_check, attention_budget, profile, arbiter.new({
		budget = attention_budget,
		silence_ms = SILENCE_MS,
		lanes = {
			{
				name = "struggle",
				lane = struggle.lane,
				priority = 1,
				gate = profile.gates.struggle,
			},
			{
				name = "progress",
				lane = progress.lane,
				priority = 2,
				gate = profile.gates.progress,
			},
			{
				name = "self_check",
				lane = self_check,
				priority = 3,
				gate = profile.gates.self_check,
			},
		},
	})
end

local function current_generation()
	return session.current().generation
end

local function reset_state()
	if state.tick_timer then
		state.tick_timer:stop()
		state.tick_timer:close()
	end

	local progress, struggle, self_check, attention_budget, trigger_profile, attention_arbiter = create_runtime()

	state.active = false
	state.generation = nil
	state.proactive_calls = 0
	state.diagnostic_signatures = {}
	state.progress = progress
	state.struggle = struggle
	state.self_check = self_check
	state.budget = attention_budget
	state.arbiter = attention_arbiter
	state.trigger_profile = trigger_profile
	state.tick_timer = nil
	state.last_dispatch_bufnr = nil
	state.running = false
end

local function can_call_backend()
	local current_config = config.get()
	local trigger_config = current_config.triggers or {}
	local max_proactive_calls = trigger_config.max_proactive_calls

	if type(max_proactive_calls) == "number" and state.proactive_calls >= max_proactive_calls then
		debug("blocked by max_proactive_calls")
		return false
	end

	return true
end

local function append_backend_error(err)
	session.report_backend_error("OpenCode backend error: " .. err)
end

local function finish_backend_check()
	state.running = false
end

local function lane_for_name(lane_name)
	if lane_name == "progress" and state.progress then
		return state.progress.lane
	end

	if lane_name == "struggle" and state.struggle then
		return state.struggle.lane
	end

	if lane_name == "self_check" and state.self_check then
		return state.self_check
	end

	return nil
end

local function reset_self_check_after_dispatch(now)
	if state.self_check then
		state.self_check:reset(now)
	end
end

local function apply_backend_outcome(lane_name, outcome, now)
	local selected_lane = lane_for_name(lane_name)

	if not selected_lane then
		return
	end

	if outcome == "silent_hold" then
		selected_lane:hold(now)
		debug(lane_name .. " held after backend outcome")
		return
	end

	selected_lane:reset(now)

	if lane_name == "progress" and state.progress then
		state.progress.save_nudged = false
	end

	debug(lane_name .. " reset after backend outcome=" .. tostring(outcome))
end

local function run_backend_check(lane_name, bufnr)
	if state.running then
		debug("ignored " .. lane_name .. " dispatch because a proactive check is already running")
		return
	end

	if not can_call_backend() then
		return
	end

	local generation = state.generation
	state.running = true
	state.proactive_calls = state.proactive_calls + 1
	reset_self_check_after_dispatch(uv.now())
	debug("backend check started for " .. lane_name)

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

		backend.prompt_async(collected_context, instructions.for_lane(lane_name), function(response, err)
			local finished_at = uv.now()

			if not session.current().active or current_generation() ~= generation then
				finish_backend_check()
				debug("backend response ignored because session changed")
				return
			end

			finish_backend_check()

			if err then
				debug("backend check failed: " .. err)
				append_backend_error(err)
				apply_backend_outcome(lane_name, "silent_hold", finished_at)
				return
			end

			debug("backend response outcome=" .. tostring(response.outcome))
			apply_backend_outcome(lane_name, response.outcome, finished_at)

			if response.outcome == "speak" then
				local appended = session.append_message("buddy", response.message, {
					severity = response.severity,
					reason = response.reason,
					trigger = lane_name,
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

local function on_diagnostics_changed(bufnr)
	local next_signatures = struggle_lane.collect_diagnostic_signatures()
	local now = uv.now()

	if state.self_check then
		state.self_check:on_activity(now)
	end

	if state.struggle then
		struggle_lane.on_diagnostics_changed(state.struggle, state.diagnostic_signatures, next_signatures, bufnr, now, debug)
	end

	state.diagnostic_signatures = next_signatures
end

local function promote_stable_diagnostics(now)
	if not state.struggle then
		return
	end

	local bufnr = struggle_lane.promote_stable_diagnostics(state.struggle, state.diagnostic_signatures, now, debug)

	if bufnr then
		state.last_dispatch_bufnr = bufnr or state.last_dispatch_bufnr
	end
end

local function run_arbiter_tick()
	if not session.current().active or current_generation() ~= state.generation then
		return
	end

	if state.running or not state.arbiter then
		return
	end

	if not can_call_backend() then
		return
	end

	local now = uv.now()
	promote_stable_diagnostics(now)

	local decision = state.arbiter:tick(now)

	if decision.action ~= "dispatch" then
		if decision.action == "blocked" then
			debug("arbiter blocked " .. tostring(decision.lane) .. " reason=" .. tostring(decision.reason))
		end

		return
	end

	debug("arbiter dispatching " .. decision.lane .. " via " .. tostring(decision.zone) .. " budget gate")
	run_backend_check(decision.lane, state.last_dispatch_bufnr or vim.api.nvim_get_current_buf())
end

local function start_tick_timer()
	if state.tick_timer then
		state.tick_timer:stop()
		state.tick_timer:close()
	end

	state.tick_timer = uv.new_timer()
	state.tick_timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(run_arbiter_tick))
end

local function on_text_changed()
	local bufnr = vim.api.nvim_get_current_buf()

	if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
		return
	end

	local now = uv.now()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local _, lines_delta = progress_lane.on_text_changed(state.progress, bufnr, now, debug)
	state.last_dispatch_bufnr = bufnr

	if state.self_check then
		state.self_check:on_activity(now)
	end

	if state.struggle then
		struggle_lane.on_text_changed(state.struggle, bufnr, now, cursor[1], lines_delta, debug)
	end
end

local function on_buffer_saved(bufnr)
	local progress = state.progress
	local now = uv.now()

	if not progress then
		return
	end

	progress_lane.on_buffer_saved(progress, now, debug)

	if state.self_check then
		state.self_check:on_activity(now)
	end

	state.last_dispatch_bufnr = bufnr
end

local function prime_baselines()
	state.diagnostic_signatures = struggle_lane.collect_diagnostic_signatures()

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			progress_lane.for_buffer(state.progress, bufnr, debug)
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
	start_tick_timer()
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
		proactive_calls = state.proactive_calls,
		diagnostic_signatures = vim.deepcopy(state.diagnostic_signatures),
		trigger_profile = vim.deepcopy(state.trigger_profile),
		last_dispatch_bufnr = state.last_dispatch_bufnr,
		running = state.running,
	}

	if state.progress then
		snapshot.progress = progress_lane.snapshot(state.progress)
	end

	if state.struggle then
		snapshot.struggle = struggle_lane.snapshot(state.struggle)
	end

	if state.self_check then
		snapshot.self_check = self_check_lane.snapshot(state.self_check)
	end

	if state.budget then
		snapshot.budget = state.budget:get_state()
	end

	if state.arbiter then
		snapshot.arbiter = state.arbiter:get_state()
	end

	return snapshot
end

return M
