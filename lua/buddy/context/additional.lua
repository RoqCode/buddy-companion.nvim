local config = require("buddy.config")

local M = {}

local uv = vim.uv or vim.loop
local FILE_LIMIT = 50 * 1024
local TOTAL_LIMIT = 200 * 1024

local function path_join(...)
	local parts = { ... }
	return table.concat(parts, "/"):gsub("//+", "/")
end

local function normalize(path)
	return vim.fs.normalize(path):gsub("/$", "")
end

local function is_within_root(path, root)
	local normalized_path = normalize(path)
	local normalized_root = normalize(root)

	return normalized_path == normalized_root or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
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

local function read_small_text_file(path, size, remaining_bytes)
	if size > FILE_LIMIT or size > remaining_bytes then
		return nil
	end

	local ok, lines = pcall(vim.fn.readfile, path, "b")

	if not ok then
		return nil
	end

	local content = table.concat(lines, "\n")

	if content:find("%z") then
		return nil
	end

	return content
end

function M.collect(current_session)
	local current_config = config.get()
	local configured_path = current_config.additional_context

	if not configured_path or configured_path == "" then
		return {
			root = nil,
			files = {},
		}
	end

	local workspace_root = normalize(current_session.workspace_root)
	local root = normalize(path_join(workspace_root, configured_path))

	if not is_within_root(root, workspace_root) then
		return {
			root = configured_path,
			files = {},
			error = "additional_context_outside_workspace",
		}
	end

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
			local absolute_path = normalize(path_join(root, path))
			local link_stat = uv.fs_lstat(absolute_path)
			local file_stat = uv.fs_stat(absolute_path)
			local size = file_stat and file_stat.size or 0
			local content = nil
			local skipped_reason = nil

			if not is_within_root(absolute_path, root) then
				skipped_reason = "outside_context_root"
			elseif link_stat and link_stat.type == "link" then
				skipped_reason = "symlink"
			elseif is_sensitive_path(path) then
				skipped_reason = "sensitive_path"
			else
				content = read_small_text_file(absolute_path, size, TOTAL_LIMIT - used_bytes)

				if content then
					used_bytes = used_bytes + #content
				elseif size > FILE_LIMIT then
					skipped_reason = "file_too_large"
				elseif size > (TOTAL_LIMIT - used_bytes) then
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

return M
