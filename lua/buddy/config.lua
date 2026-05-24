local M = {}

local defaults = {
	additional_context = ".local",
	opencode = {
		base_url = "http://127.0.0.1:4096",
		agent = "buddy",
		timeout_ms = 30000,
		auto_start = true,
		startup_timeout_ms = 5000,
	},
	triggers = {
		debounce_ms = 2000,
		cooldown_ms = 1 * 60 * 1000,
		max_proactive_calls = false,
		debug = false,
	},
	notifications = {
		floating_duration_ms = 15000,
		floating_content = "full",
		floating_preview_chars = 50,
	},
}

local config = vim.deepcopy(defaults)

function M.setup(opts)
	config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
	return vim.deepcopy(config)
end

return M
