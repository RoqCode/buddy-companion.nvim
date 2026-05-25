local M = {}

function M.for_lane(lane_name)
	if lane_name == "progress" then
		return table.concat({
			"Proactive Buddy check triggered by the Progress lane.",
			"The user appears to have finished a coherent chunk of work after recent edits.",
			"Look for one concrete observation about the current diff, diagnostics, or local project notes.",
			"Return outcome=\"silent_reset\" if there is nothing useful enough to interrupt the user.",
			"Return outcome=\"silent_hold\" only if the situation looks promising but needs a little more work before speaking.",
		}, "\n")
	end

	if lane_name == "struggle" then
		return table.concat({
			"Proactive Buddy check triggered by the Struggle lane.",
			"The user appears to be circling in a small area, undoing recent work, or sitting with stable diagnostics.",
			"Offer help only if there is one concrete way to unblock the current work.",
			"Return outcome=\"silent_reset\" if the editor already makes the issue obvious or there is no useful extra context.",
			"Return outcome=\"silent_hold\" if the user may be converging and another short observation window would be better.",
		}, "\n")
	end

	if lane_name == "self_check" then
		return table.concat({
			"Proactive Buddy check triggered by the Self-Check lane.",
			"The user has been doing continuous low-level work without another lane producing a useful intervention.",
			"Inspect the current context freely: recent diff, diagnostics, local notes, and active buffer.",
			"Speak only if there is one concrete observation, risk, useful question, or well-earned reassurance.",
			"Return outcome=\"silent_reset\" if there is nothing useful enough to interrupt the user.",
			"Return outcome=\"silent_hold\" if the situation looks promising but needs a little more work before speaking.",
		}, "\n")
	end

	return table.concat({
		"Proactive Buddy check triggered by the " .. lane_name .. " lane.",
		"Use the provided context to decide whether there is one concrete, useful thing to tell the user.",
		"Return outcome=\"silent_reset\" if the observation is generic, speculative, repeated, or not actionable.",
		"Return outcome=\"silent_hold\" only if a useful observation may be forming but is not ready yet.",
	}, "\n")
end

return M
