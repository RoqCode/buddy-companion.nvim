local config = require("buddy.config")
local session = require("buddy.session")
local chat = require("buddy.chat")
local context = require("buddy.context")

local M = {}

local function register_commands()
  vim.api.nvim_create_user_command("BuddyStart", session.start, { force = true })
  vim.api.nvim_create_user_command("BuddyStop", session.stop, { force = true })
  vim.api.nvim_create_user_command("BuddyChat", chat.open, { force = true })
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

return M
