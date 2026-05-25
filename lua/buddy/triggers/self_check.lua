local M = {}

local SelfCheck = {}
SelfCheck.__index = SelfCheck

local PARAMS = {
	check_after_ms = 10 * 60 * 1000,
	activity_idle_ms = 60 * 1000,
	hold_ratio = 0.8,
}

function M.new(opts)
	opts = opts or {}

	local self_check = {
		active_since = opts.active_since,
		last_activity_at = opts.last_activity_at,
		last_dispatch_at = opts.last_dispatch_at,
		last_status = nil,
		params = {
			check_after_ms = opts.check_after_ms or PARAMS.check_after_ms,
			activity_idle_ms = opts.activity_idle_ms or PARAMS.activity_idle_ms,
			hold_ratio = opts.hold_ratio or PARAMS.hold_ratio,
		},
	}

	return setmetatable(self_check, SelfCheck)
end

function SelfCheck:on_activity(now)
	if not self.active_since then
		self.active_since = now
	end

	self.last_activity_at = now
end

function SelfCheck:reset(now)
	self.active_since = nil
	self.last_activity_at = nil
	self.last_dispatch_at = now or self.last_dispatch_at
	self.last_status = "sleeping"
end

function SelfCheck:hold(now)
	local check_after_ms = math.max(1, self.params.check_after_ms)
	local hold_ratio = self.params.hold_ratio

	self.active_since = (now or 0) - check_after_ms * hold_ratio
	self.last_activity_at = now
	self.last_status = "armed"
end

function SelfCheck:poll(now)
	if not self.active_since or not self.last_activity_at then
		self.last_status = "sleeping"
		return self.last_status
	end

	if now - self.last_activity_at >= self.params.activity_idle_ms then
		self:reset(now)
		return self.last_status
	end

	if now - self.active_since >= self.params.check_after_ms then
		self.last_status = "ready"
		return self.last_status
	end

	self.last_status = "armed"
	return self.last_status
end

function SelfCheck:get_state()
	return {
		active_since = self.active_since,
		last_activity_at = self.last_activity_at,
		last_dispatch_at = self.last_dispatch_at,
		last_status = self.last_status,
		check_after_ms = self.params.check_after_ms,
		activity_idle_ms = self.params.activity_idle_ms,
	}
end

function M.snapshot(self_check)
	return self_check:get_state()
end

return M
