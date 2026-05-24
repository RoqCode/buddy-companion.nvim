local config = require("buddy.config")
local session = require("buddy.session")
local http = require("buddy.backend.http")
local response_parser = require("buddy.backend.response")

local M = {}

local daemon = {
	job = nil,
}

local function parse_base_url(base_url)
	local host, port = tostring(base_url):match("^https?://([^:/]+):(%d+)")

	return host or "127.0.0.1", port or "4096"
end

local function poll_health_until_ready(deadline, callback)
	M.health_async(function(response, err)
		if not err then
			session.set_backend_available(true)
			callback(response, nil)
			return
		end

		if vim.loop.now() >= deadline then
			session.set_backend_available(false)
			callback(nil, err)
			return
		end

		vim.defer_fn(function()
			poll_health_until_ready(deadline, callback)
		end, 200)
	end)
end

local function buddy_output_format()
	return {
		type = "json_schema",
		retryCount = 1,
		schema = {
			type = "object",
			properties = {
				should_speak = { type = "boolean" },
				severity = { type = "string", enum = { "info", "warning" } },
				message = { type = "string" },
				reason = { type = "string" },
			},
			required = { "should_speak", "severity", "message", "reason" },
			additionalProperties = false,
		},
	}
end

local function answer_output_format()
	return {
		type = "json_schema",
		retryCount = 1,
		schema = {
			type = "object",
			properties = {
				message = { type = "string" },
			},
			required = { "message" },
			additionalProperties = false,
		},
	}
end

local function build_system_prompt()
	return table.concat({
		"You are Buddy, a read-only pair-programming companion inside Neovim.",
		"You never edit files or suggest applying patches directly.",
		"For proactive checks, prefer silence unless there is a concrete, useful observation.",
		"Return only the requested JSON object.",
	}, "\n")
end

local function build_answer_system_prompt()
	return table.concat({
		"You are Buddy, a read-only pair-programming companion inside Neovim.",
		"Answer the user's question using the provided session context.",
		"You never edit files or suggest applying patches directly.",
		"If context is insufficient, say what is missing instead of guessing.",
		"Put the direct natural-language answer in the message field.",
		"Do not put another JSON object inside the message field.",
		"Do not use should_speak, severity, or reason for user questions.",
		"Return only the requested JSON object.",
	}, "\n")
end

local function build_prompt(collected_context, instruction)
	return vim.json.encode({
		instruction = instruction,
		context = collected_context,
	})
end

local function parse_answer_response(response)
	if response == nil then
		return nil, "OpenCode response was empty"
	end

	local text = ""

	if type(response) == "table" then
		if response.info and response.info.structured then
			local structured = response.info.structured

			if type(structured.message) == "string" then
				local ok, nested = pcall(vim.json.decode, structured.message)

				if ok and type(nested) == "table" and type(nested.message) == "string" then
					structured.message = nested.message
				end

				return structured, nil
			end
		end

		local chunks = {}

		for _, part in ipairs(response.parts or {}) do
			if part.type == "text" and part.text then
				table.insert(chunks, part.text)
			elseif part.type == "tool" and part.tool == "StructuredOutput" and part.state then
				local input = part.state.input

				if type(input) == "table" and type(input.message) == "string" then
					local ok, nested = pcall(vim.json.decode, input.message)

					if ok and type(nested) == "table" and type(nested.message) == "string" then
						input.message = nested.message
					end

					return input, nil
				end
			end
		end

		text = table.concat(chunks, "\n")
	elseif type(response) == "string" then
		text = response
	end

	local ok, parsed = pcall(vim.json.decode, text)

	if not ok or type(parsed) ~= "table" or type(parsed.message) ~= "string" then
		return nil, "OpenCode response was not valid Buddy answer JSON"
	end

	local nested_ok, nested = pcall(vim.json.decode, parsed.message)

	if nested_ok and type(nested) == "table" and type(nested.message) == "string" then
		parsed.message = nested.message
	end

	return parsed, nil
end

function M.parse_buddy_response(response)
	return response_parser.parse_buddy_response(response)
end

function M.health()
	return http.request("GET", "/global/health")
end

function M.health_async(callback)
	http.request_async("GET", "/global/health", nil, nil, callback)
end

function M.ensure_daemon_async(callback)
	M.health_async(function(response, err)
		if not err then
			session.set_backend_available(true)
			callback(response, nil, false)
			return
		end

		local current_config = config.get()

		if not current_config.opencode.auto_start then
			session.set_backend_available(false)
			callback(nil, err, false)
			return
		end

		if not daemon.job then
			local host, port = parse_base_url(current_config.opencode.base_url)

			daemon.job = vim.system({ "opencode", "serve", "--port", port, "--hostname", host }, {
				text = true,
			}, function()
				vim.schedule(function()
					daemon.job = nil
				end)
			end)
		end

		local startup_timeout_ms = current_config.opencode.startup_timeout_ms or 5000
		local deadline = vim.loop.now() + startup_timeout_ms

		poll_health_until_ready(deadline, function(ready_response, ready_err)
			callback(ready_response, ready_err, true)
		end)
	end)
end

function M.stop_daemon()
	if not daemon.job then
		return false
	end

	daemon.job:kill(15)
	daemon.job = nil
	return true
end

function M.ensure_opencode_session()
	local current_session = session.current()

	if current_session.opencode_session_id then
		return current_session.opencode_session_id, nil
	end

	local current_config = config.get()
	local body = {
		title = "Buddy Companion",
		agent = current_config.opencode.agent,
	}
	local created_session, err = http.request("POST", "/session", body, {
		directory = current_session.workspace_root,
	})

	if err then
		session.set_backend_available(false)
		return nil, err
	end

	if type(created_session) ~= "table" or type(created_session.id) ~= "string" then
		session.set_backend_available(false)
		return nil, "OpenCode session create returned an invalid session body"
	end

	session.set_backend_available(true)
	session.set_opencode_session_id(created_session.id)
	return created_session.id, nil
end

function M.ensure_opencode_session_async(callback)
	local current_session = session.current()

	if current_session.opencode_session_id then
		callback(current_session.opencode_session_id, nil)
		return
	end

	local current_config = config.get()
	local body = {
		title = "Buddy Companion",
		agent = current_config.opencode.agent,
	}

	http.request_async("POST", "/session", body, {
		directory = current_session.workspace_root,
	}, function(created_session, err)
		if err then
			session.set_backend_available(false)
			callback(nil, err)
			return
		end

		if type(created_session) ~= "table" or type(created_session.id) ~= "string" then
			session.set_backend_available(false)
			callback(nil, "OpenCode session create returned an invalid session body")
			return
		end

		session.set_backend_available(true)
		session.set_opencode_session_id(created_session.id)
		callback(created_session.id, nil)
	end)
end

function M.prompt(collected_context, instruction)
	local current_session = session.current()
	local opencode_session_id, err = M.ensure_opencode_session()

	if err then
		return nil, err
	end

	local current_config = config.get()
	local body = {
		agent = current_config.opencode.agent,
		format = buddy_output_format(),
		system = build_system_prompt(),
		parts = {
			{
				type = "text",
				text = build_prompt(collected_context, instruction),
			},
		},
	}
	local prompt_response, prompt_err = http.request("POST", "/session/" .. opencode_session_id .. "/message", body, {
		directory = current_session.workspace_root,
	})

	if prompt_err then
		session.set_backend_available(false)
		return nil, prompt_err
	end

	session.set_backend_available(true)
	return M.parse_buddy_response(prompt_response)
end

function M.prompt_async(collected_context, instruction, callback)
	local current_session = session.current()

	M.ensure_opencode_session_async(function(opencode_session_id, err)
		if err then
			callback(nil, err)
			return
		end

		local current_config = config.get()
		local body = {
			agent = current_config.opencode.agent,
			format = buddy_output_format(),
			system = build_system_prompt(),
			parts = {
				{
					type = "text",
					text = build_prompt(collected_context, instruction),
				},
			},
		}

		http.request_async("POST", "/session/" .. opencode_session_id .. "/message", body, {
			directory = current_session.workspace_root,
		}, function(prompt_response, prompt_err)
			if prompt_err then
				session.set_backend_available(false)
				callback(nil, prompt_err)
				return
			end

			session.set_backend_available(true)
			callback(M.parse_buddy_response(prompt_response))
		end)
	end)
end

function M.answer_async(collected_context, question, callback)
	local current_session = session.current()

	M.ensure_opencode_session_async(function(opencode_session_id, err)
		if err then
			callback(nil, err)
			return
		end

		local current_config = config.get()
		local body = {
			agent = current_config.opencode.agent,
			format = answer_output_format(),
			system = build_answer_system_prompt(),
			parts = {
				{
					type = "text",
					text = vim.json.encode({
						question = question,
						context = collected_context,
					}),
				},
			},
		}

		http.request_async("POST", "/session/" .. opencode_session_id .. "/message", body, {
			directory = current_session.workspace_root,
		}, function(prompt_response, prompt_err)
			if prompt_err then
				session.set_backend_available(false)
				callback(nil, prompt_err)
				return
			end

			session.set_backend_available(true)
			callback(parse_answer_response(prompt_response))
		end)
	end)
end

return M
