local M = {}

local PROFILES = {
	chatty = {
		personality = "chatty",
		budget = { max = 12, regen_factor = 0.45, regen_unit = 45 * 1000 },
		progress = { threshold_base = 5.5, quiet_window = 4500 },
		struggle = { threshold_base = 3, quiet_window = 900 },
		self_check = { check_after_ms = 6 * 60 * 1000, activity_idle_ms = 75 * 1000 },
		gates = {
			progress = { cost = 3, normal_threshold = 4 },
			struggle = { cost = 1.5, normal_threshold = 3, breakthrough_threshold = 1 },
			self_check = { cost = 4, normal_threshold = 5 },
		},
	},
	normal = {
		personality = "normal",
		budget = { max = 10, regen_factor = 0.5, regen_unit = 60 * 1000 },
		progress = { threshold_base = 7, quiet_window = 6000 },
		struggle = { threshold_base = 3.5, quiet_window = 1200 },
		self_check = { check_after_ms = 10 * 60 * 1000, activity_idle_ms = 60 * 1000 },
		gates = {
			progress = { cost = 4, normal_threshold = 5 },
			struggle = { cost = 2, normal_threshold = 4, breakthrough_threshold = 1.5 },
			self_check = { cost = 5, normal_threshold = 6 },
		},
	},
	almost_silent = {
		personality = "almost_silent",
		budget = { max = 8, regen_factor = 0.55, regen_unit = 90 * 1000 },
		progress = { threshold_base = 9, quiet_window = 9000 },
		struggle = { threshold_base = 4.5, quiet_window = 1800 },
		self_check = { check_after_ms = 18 * 60 * 1000, activity_idle_ms = 45 * 1000 },
		gates = {
			progress = { cost = 5, normal_threshold = 6.5 },
			struggle = { cost = 2.5, normal_threshold = 5, breakthrough_threshold = 2 },
			self_check = { cost = 6, normal_threshold = 7 },
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
