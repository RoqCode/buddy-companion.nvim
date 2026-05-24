local M = {}

local function extract_text(response)
  if type(response) ~= "table" then
    return ""
  end

  local chunks = {}

  for _, part in ipairs(response.parts or {}) do
    if part.type == "text" and part.text then
      table.insert(chunks, part.text)
    end
  end

  return table.concat(chunks, "\n")
end

local function extract_structured(response)
  if type(response) ~= "table" then
    return nil
  end

  if response.info and response.info.structured then
    return response.info.structured
  end

  for _, part in ipairs(response.parts or {}) do
    if part.type == "tool" and part.tool == "StructuredOutput" and part.state then
      return part.state.input
    end
  end

  return nil
end

function M.parse_buddy_response(response)
  if response == nil then
    return nil, "OpenCode response was empty"
  end

  local decoded = extract_structured(response)

  if not decoded then
    local text = type(response) == "string" and response or extract_text(response)
    local ok, parsed = pcall(vim.json.decode, text)

    if not ok then
      return nil, "OpenCode response was not valid Buddy JSON"
    end

    decoded = parsed
  end

  if type(decoded.should_speak) ~= "boolean" then
    return nil, "Buddy JSON missing boolean should_speak"
  end

  if decoded.severity ~= "info" and decoded.severity ~= "warning" then
    return nil, "Buddy JSON has invalid severity"
  end

  if type(decoded.message) ~= "string" then
    return nil, "Buddy JSON missing message"
  end

  if type(decoded.reason) ~= "string" then
    return nil, "Buddy JSON missing reason"
  end

  return decoded, nil
end

return M
