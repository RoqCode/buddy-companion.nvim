local M = {}

local Budget = {}
Budget.__index = Budget

function M.new(opts)
	opts = opts or {}

	local budget = {
		value = opts.value ~= nil and opts.value or opts.max or 10,
		last_update = opts.last_update,
		params = {
			max = opts.max or 10,
			regen_factor = opts.regen_factor or 0.5,
			regen_unit = opts.regen_unit or 60000,
		},
	}

	return setmetatable(budget, Budget)
end

function Budget:update(now)
	if not self.last_update then
		self.last_update = now
		return
	end

	local elapsed = math.max(0, now - self.last_update)
	local regen_unit = math.max(1, self.params.regen_unit)
	local remaining = self.params.max - self.value

	self.value = self.params.max - remaining * (self.params.regen_factor ^ (elapsed / regen_unit))
	self.last_update = now
end

function Budget:can_spend(lane_gate, now)
	self:update(now)

	local normal_threshold = lane_gate.normal_threshold or lane_gate.cost or self.params.max
	local breakthrough_threshold = lane_gate.breakthrough_threshold

	if self.value >= normal_threshold then
		return true, "normal"
	end

	if breakthrough_threshold and self.value >= breakthrough_threshold then
		return true, "breakthrough"
	end

	return false, "blocked"
end

function Budget:spend(cost, now)
	self:update(now)
	self.value = math.max(0, self.value - cost)
end

function Budget:get_state()
	return {
		value = self.value,
		last_update = self.last_update,
		max = self.params.max,
	}
end

return M
