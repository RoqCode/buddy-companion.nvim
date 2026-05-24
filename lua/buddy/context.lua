local config = require("buddy.config")
local session = require("buddy.session")

local M = {}

local uv = vim.uv or vim.loop
local ADDITIONAL_CONTEXT_FILE_LIMIT = 50 * 1024
local ADDITIONAL_CONTEXT_TOTAL_LIMIT = 200 * 1024

local function path_join(...)
  local parts = { ... }
  return table.concat(parts, "/"):gsub("//+", "/")
end

local function relative_path(path, root)
  local prefix = root:gsub("/$", "") .. "/"

  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return path
end

local function severity_name(severity)
  for name, value in pairs(vim.diagnostic.severity) do
    if value == severity then
      return name
    end
  end

  return tostring(severity)
end

local function is_sensitive_path(path)
  local lower_path = path:lower()
  local basename = vim.fs.basename(lower_path)

  if basename:match("^%.env") then
    return true
  end

  return lower_path:match("%.pem$")
    or lower_path:match("%.key$")
    or lower_path:match("%.crt$")
    or lower_path:match("%.p12$")
    or lower_path:match("token") ~= nil
    or lower_path:match("secret") ~= nil
end

local function looks_binary(content)
  return content:find("%z") ~= nil
end

local function read_small_text_file(path, size, remaining_bytes)
  if size > ADDITIONAL_CONTEXT_FILE_LIMIT or size > remaining_bytes then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path, "b")

  if not ok then
    return nil
  end

  local content = table.concat(lines, "\n")

  if looks_binary(content) then
    return nil
  end

  return content
end

local function collect_buffer_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)

  return {
    bufnr = bufnr,
    path = path ~= "" and path or nil,
    filetype = vim.bo[bufnr].filetype,
    cursor = {
      line = cursor[1],
      column = cursor[2],
    },
    current_line = vim.api.nvim_get_current_line(),
  }
end

local function collect_diagnostics(current_session)
  local diagnostics = {}

  for _, diagnostic in ipairs(vim.diagnostic.get()) do
    local bufnr = diagnostic.bufnr
    local path = vim.api.nvim_buf_get_name(bufnr)

    table.insert(diagnostics, {
      path = path ~= "" and relative_path(path, current_session.workspace_root) or nil,
      line = diagnostic.lnum + 1,
      column = diagnostic.col + 1,
      severity = severity_name(diagnostic.severity),
      source = diagnostic.source,
      message = diagnostic.message,
    })
  end

  return diagnostics
end

local function collect_git_diff(current_session)
  local result = vim.system({ "git", "diff", "--" }, {
    cwd = current_session.workspace_root,
    text = true,
  }):wait()

  if result.code ~= 0 then
    return {
      available = false,
      content = "",
      error = vim.trim(result.stderr or ""),
    }
  end

  return {
    available = true,
    content = result.stdout or "",
  }
end

local function collect_additional_context(current_session)
  local current_config = config.get()
  local configured_path = current_config.additional_context

  if not configured_path or configured_path == "" then
    return {
      root = nil,
      files = {},
    }
  end

  local root = path_join(current_session.workspace_root, configured_path)
  local stat = uv.fs_stat(root)

  if not stat or stat.type ~= "directory" then
    return {
      root = configured_path,
      files = {},
    }
  end

  local files = {}
  local used_bytes = 0

  for path, type in vim.fs.dir(root, { depth = math.huge }) do
    if type == "file" then
      local absolute_path = path_join(root, path)
      local file_stat = uv.fs_stat(absolute_path)
      local size = file_stat and file_stat.size or 0
      local content = nil
      local skipped_reason = nil

      if is_sensitive_path(path) then
        skipped_reason = "sensitive_path"
      else
        content = read_small_text_file(absolute_path, size, ADDITIONAL_CONTEXT_TOTAL_LIMIT - used_bytes)

        if content then
          used_bytes = used_bytes + #content
        elseif size > ADDITIONAL_CONTEXT_FILE_LIMIT then
          skipped_reason = "file_too_large"
        elseif size > (ADDITIONAL_CONTEXT_TOTAL_LIMIT - used_bytes) then
          skipped_reason = "total_limit_reached"
        else
          skipped_reason = "not_text_or_unreadable"
        end
      end

      table.insert(files, {
        path = path_join(configured_path, path),
        size = size,
        mtime = file_stat and file_stat.mtime and file_stat.mtime.sec or nil,
        content = content,
        skipped_reason = skipped_reason,
      })
    end
  end

  table.sort(files, function(left, right)
    return left.path < right.path
  end)

  return {
    root = configured_path,
    files = files,
  }
end

function M.collect()
  local current_session = session.current()

  if not current_session.active then
    vim.notify("No active Buddy session", vim.log.levels.INFO)
    return nil
  end

  return {
    workspace_root = current_session.workspace_root,
    buffer = collect_buffer_context(),
    diagnostics = collect_diagnostics(current_session),
    git_diff = collect_git_diff(current_session),
    additional_context = collect_additional_context(current_session),
  }
end

return M
