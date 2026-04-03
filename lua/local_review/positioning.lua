local M = {}

local context_radius = 2
local nearby_search_radius = 20

---@param text string?
---@return string
local function trim(text)
  text = text or ""
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param text string?
---@return string
local function normalize_text(text)
  return trim((text or ""):gsub("%s+", " "))
end

---@param lines string[]
---@param line integer
---@return string
local function line_at(lines, line)
  return lines[line] or ""
end

---@param lines string[]
---@param start_line integer
---@param end_line integer
---@return string[]
local function lines_in_range(lines, start_line, end_line)
  local selected_lines = {}
  for line = start_line, end_line do
    if line >= 1 and line <= #lines then
      selected_lines[#selected_lines + 1] = lines[line]
    end
  end
  return selected_lines
end

---@param lines string[]
---@return string[]
local function normalized_lines(lines)
  local normalized = {}
  for _, value in ipairs(lines) do
    normalized[#normalized + 1] = normalize_text(value)
  end
  return normalized
end

---@param anchor LineAnchor
---@param lines string[]
---@param line integer
---@return integer
local function context_score(anchor, lines, line)
  local score = 0

  for index, value in ipairs(anchor.normalized_before_context) do
    local candidate_line = line - (#anchor.normalized_before_context - index + 1)
    if normalize_text(line_at(lines, candidate_line)) == value then
      score = score + 1
    end
  end

  for index, value in ipairs(anchor.normalized_after_context) do
    local candidate_line = line + index
    if normalize_text(line_at(lines, candidate_line)) == value then
      score = score + 1
    end
  end

  return score
end

---@param lines string[]
---@param target string
---@param start_line integer
---@param end_line integer
---@return integer[]
local function candidate_lines(lines, target, start_line, end_line)
  local matches = {}
  for line = start_line, end_line do
    if normalize_text(line_at(lines, line)) == target then
      matches[#matches + 1] = line
    end
  end
  return matches
end

---@param start_line integer
---@param end_line integer
---@return integer[]
local function line_range(start_line, end_line)
  local matches = {}
  for line = start_line, end_line do
    matches[#matches + 1] = line
  end
  return matches
end

---@param anchor LineAnchor
---@param lines string[]
---@param matches integer[]
---@return integer|nil
local function select_candidate(anchor, lines, matches)
  if #matches == 0 then
    return nil
  end

  if #matches == 1 then
    return matches[1]
  end

  local best_line
  local best_score = -1

  for _, line in ipairs(matches) do
    local score = context_score(anchor, lines, line)
    if score > best_score then
      best_line = line
      best_score = score
    end
  end

  if best_score <= 0 then
    return nil
  end

  local nearest_line = best_line
  local nearest_distance = math.abs(best_line - anchor.line_number)
  local duplicate_nearest = false

  for _, line in ipairs(matches) do
    if context_score(anchor, lines, line) == best_score then
      local distance = math.abs(line - anchor.line_number)
      if distance < nearest_distance then
        nearest_line = line
        nearest_distance = distance
        duplicate_nearest = false
      elseif distance == nearest_distance and line ~= nearest_line then
        duplicate_nearest = true
      end
    end
  end

  if duplicate_nearest then
    return nil
  end

  return nearest_line
end

---@class LineAnchor
---@field line_number integer
---@field line_text string
---@field normalized_line_text string
---@field normalized_before_context string[]
---@field normalized_after_context string[]

---@param lines string[]
---@param line_number integer
---@return LineAnchor
function M.capture(lines, line_number)
  local before = lines_in_range(lines, line_number - context_radius, line_number - 1)
  local after = lines_in_range(lines, line_number + 1, line_number + context_radius)
  local line_text = line_at(lines, line_number)

  return {
    line_number = line_number,
    line_text = line_text,
    normalized_line_text = normalize_text(line_text),
    normalized_before_context = normalized_lines(before),
    normalized_after_context = normalized_lines(after),
  }
end

---@param anchor LineAnchor
---@param lines string[]
---@return integer|nil
function M.resolve(anchor, lines)
  local line_count = math.max(#lines, 1)
  local stored_line = math.min(anchor.line_number, line_count)
  local target = anchor.normalized_line_text

  if target == "" then
    return stored_line
  end

  if normalize_text(line_at(lines, stored_line)) == target then
    return stored_line
  end

  -- Search in nearby_search_radius first
  local start_line = math.max(1, stored_line - nearby_search_radius)
  local end_line = math.min(line_count, stored_line + nearby_search_radius)
  local matches = candidate_lines(lines, target, start_line, end_line)
  local resolved = select_candidate(anchor, lines, matches)

  if resolved then
    return resolved
  end

  -- Fallback to searching entire file
  matches = candidate_lines(lines, target, 1, line_count)
  resolved = select_candidate(anchor, lines, matches)
  if resolved then
    return resolved
  end

  -- When the target line text changes, fall back to context-only matching.
  resolved = select_candidate(anchor, lines, line_range(start_line, end_line))
  if resolved then
    return resolved
  end

  return select_candidate(anchor, lines, line_range(1, line_count))
end

return M
