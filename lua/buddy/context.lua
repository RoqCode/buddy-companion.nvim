local session = require("buddy.session")
local additional_context = require("buddy.context.additional")

local M = {}

local GIT_DIFF_LIMIT = 200 * 1024
local GIT_DIFF_TIMEOUT_MS = 2000
local UNTRACKED_FILES_LIMIT = 100

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

local function window_for_buffer(bufnr)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
			return win
		end
	end

	return nil
end

local function collect_buffer_context(opts)
	opts = opts or {}
	local win = opts.source_win
	local source_buf = opts.source_buf
	local bufnr = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf
		or win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
		or vim.api.nvim_get_current_buf()

	if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr) then
		win = window_for_buffer(bufnr)
	end

	local path = vim.api.nvim_buf_get_name(bufnr)
	local cursor = win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_cursor(win)
		or { 1, 0 }
	local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""

	return {
		bufnr = bufnr,
		path = path ~= "" and path or nil,
		filetype = vim.bo[bufnr].filetype,
		cursor = {
			line = cursor[1],
			column = cursor[2],
		},
		current_line = line,
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

local parse_git_diff_result
local parse_untracked_files_result

local function collect_git_diff(current_session)
	local result = vim.system({ "git", "diff", "HEAD", "--" }, {
		cwd = current_session.workspace_root,
		text = true,
	}):wait(GIT_DIFF_TIMEOUT_MS)
	return parse_git_diff_result(result)
end

function parse_git_diff_result(result)
	if not result then
		return {
			available = false,
			content = "",
			error = "git diff timed out",
		}
	end

	if result.code ~= 0 then
		return {
			available = false,
			content = "",
			error = vim.trim(result.stderr or ""),
		}
	end

	local content = result.stdout or ""
	local truncated = false

	if #content > GIT_DIFF_LIMIT then
		content = content:sub(1, GIT_DIFF_LIMIT)
		truncated = true
	end

	return {
		available = true,
		content = content,
		truncated = truncated,
		limit = GIT_DIFF_LIMIT,
	}
end

local function collect_untracked_files(current_session)
	local result = vim.system({ "git", "ls-files", "--others", "--exclude-standard" }, {
		cwd = current_session.workspace_root,
		text = true,
	}):wait(GIT_DIFF_TIMEOUT_MS)
	return parse_untracked_files_result(result)
end

local function run_git_async(args, current_session, on_result)
	local done = false
	local job = nil

	job = vim.system(args, {
		cwd = current_session.workspace_root,
		text = true,
	}, function(result)
		if done then
			return
		end

		done = true
		vim.schedule(function()
			on_result(result)
		end)
	end)

	vim.defer_fn(function()
		if done then
			return
		end

		done = true

		if job then
			job:kill(15)
		end

		on_result(nil)
	end, GIT_DIFF_TIMEOUT_MS)
end

function parse_untracked_files_result(result)
	if not result or result.code ~= 0 then
		return {}
	end

	local files = {}

	for _, path in ipairs(vim.split(result.stdout or "", "\n", { plain = true, trimempty = true })) do
		table.insert(files, path)

		if #files >= UNTRACKED_FILES_LIMIT then
			break
		end
	end

	return files
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
		untracked_files = collect_untracked_files(current_session),
		additional_context = additional_context.collect(current_session),
	}
end

function M.collect_async(callback, opts)
	local current_session = vim.deepcopy(session.current())

	if not current_session.active then
		vim.notify("No active Buddy session", vim.log.levels.INFO)
		callback(nil)
		return
	end

	local pending = 2
	local buffer = collect_buffer_context(opts)
	local diagnostics = collect_diagnostics(current_session)
	local additional = additional_context.collect(current_session)
	local git_diff = nil
	local untracked_files = nil

	local function finish()
		pending = pending - 1

		if pending > 0 then
			return
		end

		callback({
			workspace_root = current_session.workspace_root,
			buffer = buffer,
			diagnostics = diagnostics,
			git_diff = git_diff,
			untracked_files = untracked_files,
			additional_context = additional,
		})
	end

	run_git_async({ "git", "diff", "HEAD", "--" }, current_session, function(result)
		git_diff = parse_git_diff_result(result)
		finish()
	end)

	run_git_async({ "git", "ls-files", "--others", "--exclude-standard" }, current_session, function(result)
		untracked_files = parse_untracked_files_result(result)
		finish()
	end)
end

return M
