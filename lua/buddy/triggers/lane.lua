local M = {}

local Lane = {}
Lane.__index = Lane

local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	end

	if value > max_value then
		return max_value
	end

	return value
end

local function random_between(rng, min_value, max_value)
	return min_value + (max_value - min_value) * rng()
end

function M.new(opts)
	opts = opts or {}

	local lane = {
		mass = opts.mass ~= nil and opts.mass or 0,
		threshold = opts.threshold,
		last_update = opts.last_update,
		last_input = opts.last_input,
		peak_mass = opts.peak_mass ~= nil and opts.peak_mass or 0,
		params = {
			base = opts.base or 0.5,
			decay_factor = opts.decay_factor or 0.5,
			decay_unit = opts.decay_unit or 60000,
			mass_ceiling = opts.mass_ceiling or 20,
			arming_mass = opts.arming_mass or 3,
			threshold_base = opts.threshold_base or 6,
			jitter = opts.jitter or 0,
			quiet_window = opts.quiet_window or 3000,
			hold_ratio = opts.hold_ratio or 0.85,
		},
		rng = opts.rng or math.random,
	}

	return setmetatable(lane, Lane)
end

function Lane:apply_leak(now)
	if not self.last_update then
		self.last_update = now
		return
	end

	local elapsed = math.max(0, now - self.last_update)
	local decay_unit = math.max(1, self.params.decay_unit)

	self.mass = self.mass * (self.params.decay_factor ^ (elapsed / decay_unit))
	self.last_update = now

	if self.mass < self.params.arming_mass then
		self.threshold = nil
	end
end

function Lane:add_signal(now, signal)
	if not signal then
		return
	end

	local mass = signal.mass

	if type(mass) ~= "number" then
		local size = math.max(0, signal.size or 0)
		mass = self.params.base + math.sqrt(size)
	end

	self.mass = clamp(self.mass + mass, 0, self.params.mass_ceiling)
	self.last_input = now
	self.peak_mass = math.max(self.peak_mass, self.mass)
end

function Lane:arm_if_needed()
	if self.threshold or self.mass < self.params.arming_mass then
		return
	end

	local jitter = self.params.jitter
	self.threshold = self.params.threshold_base + random_between(self.rng, -jitter, jitter)
end

function Lane:status(now)
	if not self.threshold then
		return "sleeping"
	end

	if self.mass < self.threshold then
		return "armed"
	end

	if self.last_input and now - self.last_input >= self.params.quiet_window then
		return "ready"
	end

	return "charged"
end

function Lane:poll(now, signal)
	self:apply_leak(now)
	self:add_signal(now, signal)
	self:arm_if_needed()

	return self:status(now)
end

function Lane:reset(now)
	self.mass = 0
	self.threshold = nil
	self.last_update = now or self.last_update
	self.last_input = nil
	self.peak_mass = 0
end

function Lane:hold(now)
	if self.threshold then
		self.mass = math.min(self.params.mass_ceiling, self.threshold * self.params.hold_ratio)
	end

	self.last_update = now or self.last_update
	self.last_input = nil
	self.peak_mass = self.mass
end

function Lane:lower_threshold(amount)
	if not self.threshold then
		return false
	end

	self.threshold = math.max(self.params.arming_mass, self.threshold - amount)
	return true
end

function Lane:get_state()
	return {
		mass = self.mass,
		threshold = self.threshold,
		last_update = self.last_update,
		last_input = self.last_input,
		peak_mass = self.peak_mass,
	}
end

return M
