local config = require("buddy.config")
local session = require("buddy.session")
local chat = require("buddy.chat")
local context = require("buddy.context")
local backend = require("buddy.backend")

local M = {}

local function show_status(content)
  if session.current().active then
    session.append_message("system", content)
  else
    vim.notify(content, vim.log.levels.INFO)
  end
end

local function show_backend_error(content)
  if session.current().active then
    session.report_backend_error(content)
  else
    vim.notify(content, vim.log.levels.INFO)
  end
end

local function backend_health()
  backend.health_async(function(response, err)
    if err then
      show_backend_error("OpenCode backend unavailable: " .. err)
      return
    end

    session.set_backend_available(true)
    show_status("OpenCode backend healthy: " .. (response.version or "unknown version"))
  end)
end

local function backend_test()
  context.collect_async(function(collected_context)
    if not collected_context then
      return
    end

    backend.prompt_async(
      collected_context,
      "Manual backend test. Say whether there is anything important to mention about this current context. Prefer should_speak=false unless something is concrete.",
      function(response, err)
        if err then
          show_backend_error("OpenCode backend error: " .. err)
          return
        end

        if response.should_speak then
          session.append_message("buddy", response.message, {
            severity = response.severity,
            reason = response.reason,
          })
        end
      end
    )
  end)
end

local function register_commands()
  vim.api.nvim_create_user_command("BuddyStart", session.start, { force = true })
  vim.api.nvim_create_user_command("BuddyStop", session.stop, { force = true })
  vim.api.nvim_create_user_command("BuddyChat", chat.open, { force = true })
  vim.api.nvim_create_user_command("BuddyBackendHealth", backend_health, { force = true })
  vim.api.nvim_create_user_command("BuddyBackendTest", backend_test, { force = true })
end

function M.setup(opts)
  config.setup(opts)
  session.set_on_change(chat.render)
  register_commands()
end

function M.get_config()
  return config.get()
end

function M.get_session()
  return session.get()
end

function M._append_message(role, content, meta)
  return session.append_message(role, content, meta)
end

function M._collect_context()
  return context.collect()
end

function M._collect_context_async(callback)
  return context.collect_async(callback)
end

function M._backend_health()
  return backend.health()
end

function M._backend_health_async(callback)
  return backend.health_async(callback)
end

function M._parse_buddy_response(response)
  return backend.parse_buddy_response(response)
end

return M
