local config = require("buddy.config")

local M = {}

local NODE_SCRIPT = [[
const http = require("http")
const https = require("https")

const method = process.argv[1]
const target = new URL(process.argv[2])
const timeout = Number(process.argv[3])
let body = ""

process.stdin.on("data", chunk => body += chunk)
process.stdin.on("end", () => {
  const client = target.protocol === "https:" ? https : http
  const req = client.request(target, {
    method,
    headers: {
      "content-type": "application/json",
      "accept": "application/json",
      "content-length": Buffer.byteLength(body),
    },
  }, res => {
    let response = ""
    res.on("data", chunk => response += chunk)
    res.on("end", () => {
      process.stdout.write(JSON.stringify({ status: res.statusCode, body: response }))
    })
  })

  req.on("error", err => {
    process.stdout.write(JSON.stringify({ error: err.message }))
  })

  req.setTimeout(timeout, () => {
    req.destroy(new Error("Request timed out after " + timeout + "ms"))
  })

  req.end(body)
})
]]

local function trim_slash(value)
  return value:gsub("/+$", "")
end

local function encode_query(value)
  return tostring(value):gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function url(path, query)
  local current_config = config.get()
  local result = trim_slash(current_config.opencode.base_url) .. path

  if query and next(query) then
    local parts = {}

    for key, value in pairs(query) do
      if value ~= nil then
        table.insert(parts, encode_query(key) .. "=" .. encode_query(value))
      end
    end

    table.sort(parts)

    if #parts > 0 then
      result = result .. "?" .. table.concat(parts, "&")
    end
  end

  return result
end

local function request_args(method, path, body, query)
  local current_config = config.get()
  local request_url = url(path, query)
  local payload = body and vim.json.encode(body) or ""
  local timeout_ms = current_config.opencode.timeout_ms or 30000

  return { "node", "-e", NODE_SCRIPT, method, request_url, tostring(timeout_ms) }, payload, timeout_ms
end

local function parse_result(result)
  if not result then
    return nil, "HTTP request timed out"
  end

  if result.code ~= 0 then
    return nil, vim.trim(result.stderr or "HTTP request failed")
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout)

  if not ok then
    return nil, "Failed to decode HTTP response wrapper"
  end

  if decoded.error then
    return nil, decoded.error
  end

  local response_body = nil

  if decoded.body and decoded.body ~= "" then
    local body_ok, parsed = pcall(vim.json.decode, decoded.body)

    if body_ok then
      response_body = parsed
    else
      response_body = decoded.body
    end
  end

  if decoded.status < 200 or decoded.status >= 300 then
    return nil, string.format("OpenCode returned HTTP %s", decoded.status), response_body
  end

  return response_body, nil, decoded.status
end

function M.request(method, path, body, query)
  local args, payload, timeout_ms = request_args(method, path, body, query)
  local result = vim.system(args, {
    stdin = payload,
    text = true,
  }):wait(timeout_ms + 1000)

  return parse_result(result)
end

function M.request_async(method, path, body, query, callback)
  local args, payload = request_args(method, path, body, query)

  vim.system(args, {
    stdin = payload,
    text = true,
  }, function(result)
    local response_body, err, status = parse_result(result)

    vim.schedule(function()
      callback(response_body, err, status)
    end)
  end)
end

return M
