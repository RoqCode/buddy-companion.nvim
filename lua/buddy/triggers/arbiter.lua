local M = {}

local Arbiter = {}
Arbiter.__index = Arbiter

local function lane_priority(left, right)
	return left.priority < right.priority
end

function M.new(opts)
	opts = opts or {}

	local lanes = {}

	for _, lane_config in ipairs(opts.lanes or {}) do
		table.insert(lanes, {
			name = lane_config.name,
			lane = lane_config.lane,
			priority = lane_config.priority or 100,
			gate = lane_config.gate or {},
		})
	end

	table.sort(lanes, lane_priority)

	local arbiter = {
		lanes = lanes,
		budget = opts.budget,
		silence_ms = opts.silence_ms or 1500,
		last_spoke_at = opts.last_spoke_at,
		last_decision = nil,
	}

	return setmetatable(arbiter, Arbiter)
end

function Arbiter:poll_lanes(now, signals)
	local ready = {}
	local statuses = {}

	for _, lane_config in ipairs(self.lanes) do
		local signal = signals and signals[lane_config.name] or nil
		local status = lane_config.lane:poll(now, signal)

		statuses[lane_config.name] = status

		if status == "ready" then
			table.insert(ready, lane_config)
		end
	end

	return ready, statuses
end

function Arbiter:tick(now, signals)
	local ready, statuses = self:poll_lanes(now, signals)

	if #ready == 0 then
		self.last_decision = {
			action = "idle",
			reason = "no_ready_lanes",
			statuses = statuses,
		}

		return self.last_decision
	end

	table.sort(ready, lane_priority)

	local selected = ready[1]

	if self.last_spoke_at and now - self.last_spoke_at < self.silence_ms then
		self.last_decision = {
			action = "blocked",
			reason = "silence_interval",
			lane = selected.name,
			statuses = statuses,
		}

		return self.last_decision
	end

	local can_spend, zone = self.budget:can_spend(selected.gate, now)

	if not can_spend then
		self.last_decision = {
			action = "blocked",
			reason = "budget",
			lane = selected.name,
			zone = zone,
			statuses = statuses,
		}

		return self.last_decision
	end

	self.budget:spend(selected.gate.cost or 0, now)
	self.last_spoke_at = now
	self.last_decision = {
		action = "dispatch",
		lane = selected.name,
		zone = zone,
		statuses = statuses,
	}

	return self.last_decision
end

function Arbiter:get_state()
	local lanes = {}

	for _, lane_config in ipairs(self.lanes) do
		lanes[lane_config.name] = lane_config.lane:get_state()
	end

	return {
		lanes = lanes,
		budget = self.budget and self.budget:get_state() or nil,
		last_spoke_at = self.last_spoke_at,
		last_decision = self.last_decision,
	}
end

return M
