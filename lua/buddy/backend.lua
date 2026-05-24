local config = require("buddy.config")
local session = require("buddy.session")
local http = require("buddy.backend.http")
local response_parser = require("buddy.backend.response")

local M = {}

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

local function build_system_prompt()
  return table.concat({
    "You are Buddy, a read-only pair-programming companion inside Neovim.",
    "You never edit files or suggest applying patches directly.",
    "For proactive checks, prefer silence unless there is a concrete, useful observation.",
    "Return only the requested JSON object.",
  }, "\n")
end

local function build_prompt(collected_context, instruction)
  return vim.json.encode({
    instruction = instruction,
    context = collected_context,
  })
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

return M
