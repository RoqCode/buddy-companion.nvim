local lane = require("buddy.triggers.lane")

local M = {}

local PARAMS = {
	base = 0.5,
	decay_factor = 0.5,
	decay_unit = 20 * 1000,
	mass_ceiling = 10,
	arming_mass = 2,
	threshold_base = 3.5,
	jitter = 0.5,
	quiet_window = 1200,
	hold_ratio = 0.85,
}

local STABLE_DIAGNOSTIC_MS = 2500
local STABLE_DIAGNOSTIC_MASS = 0.8
local REPEATED_EDIT_WINDOW_MS = 8000
local REPEATED_EDIT_LINE_RADIUS = 5
local REPEATED_EDIT_MIN_COUNT = 4
local REPEATED_EDIT_MASS = 0.7
local UNDO_OSCILLATION_MASS = 1.5

local IMPORTANT_DIAGNOSTICS = {
	[vim.diagnostic.severity.ERROR] = true,
	[vim.diagnostic.severity.WARN] = true,
}

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

function M.collect_diagnostic_signatures()
	local signatures = {}

	for _, diagnostic in ipairs(vim.diagnostic.get()) do
		if IMPORTANT_DIAGNOSTICS[diagnostic.severity] then
			signatures[diagnostic_signature(diagnostic)] = true
		end
	end

	return signatures
end

function M.has_new_diagnostics(previous_signatures, next_signatures)
	for signature in pairs(next_signatures) do
		if not previous_signatures[signature] then
			return true
		end
	end

	return false
end

function M.new()
	return {
		lane = lane.new(PARAMS),
		buffers = {},
		pending_diagnostics = {},
		last_status = nil,
	}
end

function M.for_buffer(struggle, bufnr)
	if not struggle.buffers[bufnr] then
		local ok, undo = pcall(vim.fn.undotree)

		struggle.buffers[bufnr] = {
			last_edit_line = nil,
			last_edit_at = nil,
			repeated_count = 0,
			undo_seq = ok and undo.seq_cur or nil,
		}
	end

	return struggle.buffers[bufnr]
end

function M.poll(struggle, now, signal, debug)
	local status = struggle.lane:poll(now, signal)
	struggle.last_status = status

	if debug then
		debug("struggle status=" .. status .. " mass=" .. string.format("%.2f", struggle.lane.mass))
	end

	return status
end

function M.on_diagnostics_changed(struggle, previous_signatures, next_signatures, bufnr, now, debug)
	for signature in pairs(next_signatures) do
		if not previous_signatures[signature] and not struggle.pending_diagnostics[signature] then
			struggle.pending_diagnostics[signature] = {
				first_seen = now,
				bufnr = bufnr or vim.api.nvim_get_current_buf(),
			}
		end
	end

	for signature in pairs(struggle.pending_diagnostics) do
		if not next_signatures[signature] then
			struggle.pending_diagnostics[signature] = nil
		end
	end

	if debug then
		if M.has_new_diagnostics(previous_signatures, next_signatures) then
			debug("new diagnostic observed for Struggle stability check")
		else
			debug("diagnostic event without new WARN/ERROR")
		end
	end
end

function M.promote_stable_diagnostics(struggle, diagnostic_signatures, now, debug)
	local mass = 0
	local bufnr = nil

	for signature, pending in pairs(struggle.pending_diagnostics) do
		if diagnostic_signatures[signature] then
			if now - pending.first_seen >= STABLE_DIAGNOSTIC_MS then
				mass = mass + STABLE_DIAGNOSTIC_MASS
				bufnr = pending.bufnr or bufnr
				struggle.pending_diagnostics[signature] = nil
			end
		else
			struggle.pending_diagnostics[signature] = nil
		end
	end

	if mass == 0 then
		return nil
	end

	M.poll(struggle, now, { mass = mass }, debug)

	if debug then
		debug("stable diagnostics added struggle mass=" .. tostring(mass))
	end

	return bufnr
end

function M.on_text_changed(struggle, bufnr, now, edit_line, lines_delta, debug)
	local buffer_state = M.for_buffer(struggle, bufnr)
	local mass = 0
	local ok, undo = pcall(vim.fn.undotree)

	if ok and type(undo.seq_cur) == "number" then
		if buffer_state.undo_seq and undo.seq_cur < buffer_state.undo_seq then
			mass = mass + UNDO_OSCILLATION_MASS

			if debug then
				debug("undo oscillation added struggle mass")
			end
		end

		buffer_state.undo_seq = undo.seq_cur
	end

	local repeated = false

	if buffer_state.last_edit_line and buffer_state.last_edit_at then
		repeated = math.abs(edit_line - buffer_state.last_edit_line) <= REPEATED_EDIT_LINE_RADIUS
			and now - buffer_state.last_edit_at <= REPEATED_EDIT_WINDOW_MS
			and math.abs(lines_delta) <= 1
	end

	if repeated then
		buffer_state.repeated_count = buffer_state.repeated_count + 1
	else
		buffer_state.repeated_count = 1
	end

	buffer_state.last_edit_line = edit_line
	buffer_state.last_edit_at = now

	if buffer_state.repeated_count >= REPEATED_EDIT_MIN_COUNT then
		mass = mass + REPEATED_EDIT_MASS
	end

	if mass == 0 then
		return nil
	end

	local status = struggle.lane:poll(now, { mass = mass })
	struggle.last_status = status

	if debug then
		debug("struggle text signal mass=" .. tostring(mass) .. " status=" .. status)
	end

	return status
end

function M.snapshot(struggle)
	return {
		lane = struggle.lane:get_state(),
		last_status = struggle.last_status,
		buffers = vim.deepcopy(struggle.buffers),
		pending_diagnostics = vim.deepcopy(struggle.pending_diagnostics),
	}
end

return M
