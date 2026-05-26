local M = {}

local PROFILES = {
	chatty = {
		personality = "chatty",
		budget = { max = 9, regen_factor = 0.6, regen_unit = 75 * 1000 },
		progress = { threshold_base = 7, quiet_window = 7000 },
		struggle = { threshold_base = 5, quiet_window = 2200 },
		self_check = { check_after_ms = 3 * 60 * 1000, activity_idle_ms = 75 * 1000 },
		gates = {
			progress = { cost = 4, normal_threshold = 5.5 },
			struggle = { cost = 3, normal_threshold = 5 },
			self_check = { cost = 2.5, normal_threshold = 3.5 },
		},
	},
	normal = {
		personality = "normal",
		budget = { max = 9, regen_factor = 0.62, regen_unit = 80 * 1000 },
		progress = { threshold_base = 8, quiet_window = 8500 },
		struggle = { threshold_base = 6, quiet_window = 2800 },
		self_check = { check_after_ms = 4 * 60 * 1000, activity_idle_ms = 75 * 1000 },
		gates = {
			progress = { cost = 4.2, normal_threshold = 6 },
			struggle = { cost = 3.2, normal_threshold = 5.5 },
			self_check = { cost = 2.7, normal_threshold = 3.7 },
		},
	},
	almost_silent = {
		personality = "almost_silent",
		budget = { max = 7, regen_factor = 0.7, regen_unit = 120 * 1000 },
		progress = { threshold_base = 10, quiet_window = 12000 },
		struggle = { threshold_base = 8, quiet_window = 4500 },
		self_check = { check_after_ms = 7 * 60 * 1000, activity_idle_ms = 75 * 1000 },
		gates = {
			progress = { cost = 5.5, normal_threshold = 6.8 },
			struggle = { cost = 4.5, normal_threshold = 6.5 },
			self_check = { cost = 3.5, normal_threshold = 4.5 },
		},
	},
}

function M.resolve(trigger_config)
	trigger_config = trigger_config or {}

	local personality = trigger_config.personality or "normal"
	local profile = PROFILES[personality]

	if not profile then
		vim.notify(
			"Buddy trigger: unknown personality " .. tostring(personality) .. ", falling back to normal",
			vim.log.levels.WARN
		)
		profile = PROFILES.normal
	end

	return vim.deepcopy(profile)
end

return M
