local M = {}

---@class LocalReviewComment
---@field id string
---@field repo_root string
---@field absolute_path string
---@field relative_path string
---@field line integer
---@field body string
---@field created_at string
---@field updated_at string
---@field source_kind string
---@field source_meta table
---@field stale boolean
---@field anchor_line_text string?
---@field anchor_line_text_normalized string?
---@field before_context string[]?
---@field before_context_normalized string[]?
---@field after_context string[]?
---@field after_context_normalized string[]?

local context = require("local_review.context")
local storage = require("local_review.storage")

local anchor_context_radius = 2
local nearby_search_radius = 20

local state = {
  file_fingerprints = {},
}

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function hrtime()
  ---@diagnostic disable-next-line: undefined-field
  return vim.uv.hrtime()
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

---@param text string
---@return string
local function normalize_text(text)
  return vim.trim(text:gsub("%s+", " "))
end

---@param lines string[]
---@return integer
local function line_count(lines)
  return math.max(#lines, 1)
end

---@param bufnr integer
---@return string[]
local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param lines string[]
---@param line integer
---@return string
local function line_at(lines, line)
  if line < 1 or line > #lines then
    return ""
  end
  return lines[line]
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

---@param lines string[]
---@param line integer
---@return table
local function anchor_for_line(lines, line)
  local before = lines_in_range(lines, line - anchor_context_radius, line - 1)
  local after = lines_in_range(lines, line + 1, line + anchor_context_radius)
  return {
    anchor_line_text = line_at(lines, line),
    anchor_line_text_normalized = normalize_text(line_at(lines, line)),
    before_context = before,
    before_context_normalized = normalized_lines(before),
    after_context = after,
    after_context_normalized = normalized_lines(after),
  }
end

---@param comment table
---@param lines string[]
---@param line integer
local function apply_anchor(comment, lines, line)
  local anchor = anchor_for_line(lines, line)
  comment.line = line
  comment.anchor_line_text = anchor.anchor_line_text
  comment.anchor_line_text_normalized = anchor.anchor_line_text_normalized
  comment.before_context = anchor.before_context
  comment.before_context_normalized = anchor.before_context_normalized
  comment.after_context = anchor.after_context
  comment.after_context_normalized = anchor.after_context_normalized
  comment.stale = false
end

local function ensure_comment_defaults(comment)
  if comment.id == nil or comment.id == "" then
    comment.id = tostring(hrtime())
  end
  if comment.stale == nil then
    comment.stale = false
  end
end

local function loaded_repo()
  local repo, err = storage.for_current_repo()
  if not repo then
    notify(err, vim.log.levels.WARN)
    return nil
  end
  return repo
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function refresh_repo_buffers(repo_root)
  local markers = require("local_review.markers")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.repo_root(path)
        if root == repo_root then
          markers.refresh(bufnr)
        end
      end
    end
  end
end

local function persist_repo_state(repo_root, data)
  local ok, err = storage.save_repo(repo_root, data)
  if not ok then
    return nil, err
  end

  refresh_repo_buffers(repo_root)
  return true
end

local function comment_sorter(a, b)
  if a.relative_path ~= b.relative_path then
    return a.relative_path < b.relative_path
  end
  if a.line ~= b.line then
    return a.line < b.line
  end
  return (a.created_at or "") < (b.created_at or "")
end

---@param lines string[]
---@return string
local function buffer_fingerprint(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

---@param comment table
---@param lines string[]
---@param line integer
---@return integer
local function context_score(comment, lines, line)
  local score = 0
  local before = comment.before_context_normalized or {}
  local after = comment.after_context_normalized or {}

  for index, value in ipairs(before) do
    local candidate_line = line - (#before - index + 1)
    if normalize_text(line_at(lines, candidate_line)) == value then
      score = score + 1
    end
  end

  for index, value in ipairs(after) do
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

---@param comment table
---@param lines string[]
---@param matches integer[]
---@return integer|nil
local function select_candidate(comment, lines, matches)
  if #matches == 0 then
    return nil
  end

  if #matches == 1 then
    return matches[1]
  end

  local best_line
  local best_score = -1
  local duplicate_best = false

  for _, line in ipairs(matches) do
    local score = context_score(comment, lines, line)
    if score > best_score then
      best_line = line
      best_score = score
      duplicate_best = false
    elseif score == best_score then
      duplicate_best = true
    end
  end

  if duplicate_best or best_score <= 0 then
    return nil
  end

  return best_line
end

local function reconcile_comment(comment, lines)
  ensure_comment_defaults(comment)

  local max_line = line_count(lines)
  local stored_line = math.max(1, math.min(comment.line or 1, max_line))
  local target = comment.anchor_line_text_normalized or normalize_text(comment.anchor_line_text)

  if target == "" then
    apply_anchor(comment, lines, stored_line)
    return true
  end

  if normalize_text(line_at(lines, stored_line)) == target then
    local was_stale = comment.stale
    apply_anchor(comment, lines, stored_line)
    return was_stale or false
  end

  local start_line = math.max(1, stored_line - nearby_search_radius)
  local end_line = math.min(max_line, stored_line + nearby_search_radius)
  local matches = candidate_lines(lines, target, start_line, end_line)
  local resolved = select_candidate(comment, lines, matches)

  if not resolved then
    matches = candidate_lines(lines, target, 1, max_line)
    resolved = select_candidate(comment, lines, matches)
  end

  if resolved then
    local moved = comment.line ~= resolved or comment.stale
    apply_anchor(comment, lines, resolved)
    return moved
  end

  if not comment.stale then
    comment.stale = true
    return true
  end

  return false
end

local function reconcile_buffer_state(bufnr, repo_state, ctx)
  local lines = buffer_lines(bufnr)
  local fingerprint = buffer_fingerprint(lines)
  local previous = state.file_fingerprints[ctx.absolute_path]
  local comments = repo_state.data.comments

  if previous == fingerprint then
    return repo_state
  end

  local changed = false
  for _, comment in ipairs(comments) do
    if comment.relative_path == ctx.relative_path then
      comment.absolute_path = ctx.absolute_path
      comment.repo_root = ctx.repo_root
      if reconcile_comment(comment, lines) then
        changed = true
      end
    end
  end

  if changed then
    local ok, err = storage.save_repo(ctx.repo_root, repo_state.data)
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end

  state.file_fingerprints[ctx.absolute_path] = fingerprint
  return repo_state
end

local function repo_state_for_buffer(bufnr)
  local ctx, err = context.comment_context(bufnr)
  if not ctx then
    return nil, err
  end

  local repo_state = {
    repo_root = ctx.repo_root,
    data = storage.load_repo(ctx.repo_root),
  }

  reconcile_buffer_state(bufnr or 0, repo_state, ctx)
  return {
    ctx = ctx,
    repo_state = repo_state,
  }
end

---@return LocalReviewComment, boolean
local function upsert_comment(repo_state, ctx, line, body)
  local comments = repo_state.data.comments
  local existing

  for _, comment in ipairs(comments) do
    ensure_comment_defaults(comment)
    if comment.relative_path == ctx.relative_path and comment.line == line then
      existing = comment
      break
    end
  end

  local timestamp = now()
  local lines = buffer_lines(ctx.bufnr)
  if existing then
    existing.body = body
    existing.updated_at = timestamp
    existing.absolute_path = ctx.absolute_path
    existing.repo_root = ctx.repo_root
    apply_anchor(existing, lines, line)
    return existing, true
  end

  local filetype = vim.bo[ctx.bufnr].filetype or ""
  local source_kind = filetype:match("^Diffview") and "diffview" or "buffer"
  local comment = {
    id = tostring(hrtime()),
    repo_root = ctx.repo_root,
    absolute_path = ctx.absolute_path,
    relative_path = ctx.relative_path,
    line = line,
    body = body,
    created_at = timestamp,
    updated_at = timestamp,
    source_kind = source_kind,
    source_meta = {},
    stale = false,
  }

  apply_anchor(comment, lines, line)
  table.insert(comments, comment)
  return comment, false
end

local function find_current_comment()
  local resolved, err = repo_state_for_buffer(0)
  if not resolved then
    notify(err, vim.log.levels.WARN)
    return nil
  end

  local line = current_line()
  for index, comment in ipairs(resolved.repo_state.data.comments) do
    if comment.relative_path == resolved.ctx.relative_path and comment.line == line then
      return {
        ---@type LocalReviewComment
        comment = comment,
        index = index,
        ctx = resolved.ctx,
        repo_state = resolved.repo_state,
      }
    end
  end

  return {
    ---@type LocalReviewComment?
    comment = nil,
    index = nil,
    ctx = resolved.ctx,
    repo_state = resolved.repo_state,
  }
end

local function find_line_comment(bufnr, line)
  local resolved, err = repo_state_for_buffer(bufnr)
  if not resolved then
    return nil, err
  end

  for index, comment in ipairs(resolved.repo_state.data.comments) do
    if comment.relative_path == resolved.ctx.relative_path and comment.line == line then
      return {
        comment = comment,
        index = index,
        ctx = resolved.ctx,
        repo_state = resolved.repo_state,
      }
    end
  end

  return {
    ---@type LocalReviewComment?
    comment = nil,
    index = nil,
    ctx = resolved.ctx,
    repo_state = resolved.repo_state,
  }
end

function M.status_label(comment)
  if comment and comment.stale then
    return "stale"
  end
  return nil
end

function M.list_repo_comments(repo_root)
  local data = storage.load_repo(repo_root)
  for _, comment in ipairs(data.comments) do
    ensure_comment_defaults(comment)
  end
  table.sort(data.comments, comment_sorter)
  return data.comments
end

function M.comments_for_buffer(bufnr)
  local resolved, err = repo_state_for_buffer(bufnr or 0)
  if not resolved then
    notify(err, vim.log.levels.WARN)
    return {}
  end

  local comments = M.list_repo_comments(resolved.ctx.repo_root)
  local matches = {}
  for _, comment in ipairs(comments) do
    if comment.relative_path == resolved.ctx.relative_path then
      table.insert(matches, comment)
    end
  end
  return matches
end

function M.get_line_state(bufnr, line)
  local result, err = find_line_comment(bufnr or 0, line)
  if not result then
    notify(err, vim.log.levels.WARN)
    return nil
  end

  return result
end

function M.upsert_line_comment(line_state, body)
  local trimmed = vim.trim(body or "")
  if trimmed == "" then
    return nil, "Comment cannot be empty."
  end

  local _, updated = upsert_comment(
    line_state.repo_state,
    line_state.ctx,
    line_state.comment and line_state.comment.line or current_line(),
    trimmed
  )
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return updated and "updated" or "created"
end

function M.set_line_comment(bufnr, line, body)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  local trimmed = vim.trim(body or "")
  if trimmed == "" then
    if line_state.index ~= nil then
      table.remove(line_state.repo_state.data.comments, line_state.index)
      local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
      if not ok then
        return nil, err
      end
      return "deleted"
    end

    return "noop"
  end

  local _, updated = upsert_comment(line_state.repo_state, line_state.ctx, line, trimmed)
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return updated and "updated" or "created"
end

function M.delete_line_comment(bufnr, line)
  local line_state = M.get_line_state(bufnr, line)
  if not line_state then
    return nil, "Unable to resolve comment target."
  end

  if line_state.index == nil then
    return "missing"
  end

  table.remove(line_state.repo_state.data.comments, line_state.index)
  local ok, err = persist_repo_state(line_state.ctx.repo_root, line_state.repo_state.data)
  if not ok then
    return nil, err
  end
  return "deleted"
end

function M.prompt_for_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  local line = current_line()
  local prompt = result.comment and "Edit review comment" or "Add review comment"
  local default = result.comment and result.comment.body or ""

  vim.ui.input({
    prompt = string.format("%s (%s:%d): ", prompt, result.ctx.relative_path, line),
    default = default,
  }, function(input)
    if input == nil then
      return
    end

    local trimmed = vim.trim(input)
    if trimmed == "" then
      notify("Comment cannot be empty.", vim.log.levels.WARN)
      return
    end

    local _, updated = upsert_comment(result.repo_state, result.ctx, line, trimmed)
    local ok, err = persist_repo_state(result.ctx.repo_root, result.repo_state.data)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
    notify(updated and "Review comment updated." or "Review comment added.")
  end)
end

function M.delete_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  if result.index == nil then
    notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end

  table.remove(result.repo_state.data.comments, result.index)
  local ok, err = persist_repo_state(result.ctx.repo_root, result.repo_state.data)
  if not ok then
    notify(err, vim.log.levels.ERROR)
    return
  end
  notify("Review comment deleted.")
end

function M.jump(direction)
  local comments = M.comments_for_buffer(0)
  if #comments == 0 then
    notify("No review comments in the current buffer.", vim.log.levels.INFO)
    return
  end

  local line = current_line()
  table.sort(comments, function(a, b)
    return a.line < b.line
  end)

  local target
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.line > line then
        target = comment
        break
      end
    end
    target = target or comments[1]
  else
    for index = #comments, 1, -1 do
      if comments[index].line < line then
        target = comments[index]
        break
      end
    end
    target = target or comments[#comments]
  end

  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local line = math.max(1, math.min(target.line or 1, max_line))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  if target.stale then
    notify("Jumped to a stale review comment.", vim.log.levels.WARN)
  end
end

function M.clear_repo()
  local repo_state = loaded_repo()
  if not repo_state then
    return
  end

  repo_state.data.comments = {}
  local deleted = storage.delete_repo(repo_state.repo_root)
  if not deleted then
    local ok, err = persist_repo_state(repo_state.repo_root, repo_state.data)
    if not ok then
      notify(err, vim.log.levels.ERROR)
      return
    end
  else
    refresh_repo_buffers(repo_state.repo_root)
  end
  notify("Cleared review comments for current repo.")
end

return M
