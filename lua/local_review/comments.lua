local M = {}

---@class LocalReviewComment
---@field id string
---@field absolute_path string
---@field body string
---@field created_at string
---@field updated_at string
---@field source_kind string
---@field source_meta table
---@field stale boolean
---@field anchor LineAnchor

local context = require("local_review.context")
local positioning = require("local_review.positioning")
local storage = require("local_review.storage")

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

---@param bufnr integer
---@return string[]
local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param comment LocalReviewComment
---@param lines string[]
---@param line integer
local function apply_anchor(comment, lines, line)
  comment.anchor = positioning.capture(lines, line)
  comment.stale = false
end

---@param comment LocalReviewComment
local function ensure_comment_defaults(comment)
  if comment.id == "" then
    comment.id = tostring(hrtime())
  end
  if comment.stale == nil then
    comment.stale = false
  end
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function refresh_scope_buffers(scope_root)
  local markers = require("local_review.markers")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.scope_root(path)
        if root == scope_root then
          markers.refresh(bufnr)
        end
      end
    end
  end
end

local function persist_scope_state(scope_root, data, opts)
  local ok, err = storage.save_scope(scope_root, data, opts)
  if not ok then
    return nil, err
  end

  refresh_scope_buffers(scope_root)
  return true
end

local function comment_sorter(a, b)
  if a.absolute_path ~= b.absolute_path then
    return a.absolute_path < b.absolute_path
  end
  if a.anchor.line_number ~= b.anchor.line_number then
    return a.anchor.line_number < b.anchor.line_number
  end
  return (a.created_at or "") < (b.created_at or "")
end

---@param lines string[]
---@return string
local function buffer_fingerprint(lines)
  return vim.fn.sha256(table.concat(lines, "\n"))
end

---@param comment LocalReviewComment
---@param lines string[]
---@return boolean
local function reconcile_comment(comment, lines)
  ensure_comment_defaults(comment)

  local resolved = positioning.resolve(comment.anchor, lines)
  if not resolved then
    if not comment.stale then
      comment.stale = true
      return true
    end
    return false
  end

  if comment.anchor.line_number == resolved and not comment.stale then
    apply_anchor(comment, lines, resolved)
    return false
  end

  local moved = comment.anchor.line_number ~= resolved or comment.stale
  apply_anchor(comment, lines, resolved)
  return moved
end

local function clamp_line(line, lines)
  local max_line = math.max(#lines, 1)
  return math.max(1, math.min(line, max_line))
end

local function find_comment_at_line(comments, absolute_path, line)
  for _, comment in ipairs(comments) do
    ensure_comment_defaults(comment)
    if comment.absolute_path == absolute_path and comment.anchor.line_number == line then
      return comment
    end
  end
  return nil
end

local function find_comment_entry_at_line(comments, absolute_path, line)
  for index, comment in ipairs(comments) do
    ensure_comment_defaults(comment)
    if comment.absolute_path == absolute_path and comment.anchor.line_number == line then
      return comment, index
    end
  end
  return nil, nil
end

local function reconcile_buffer_state(bufnr, scope_state, ctx)
  local lines = buffer_lines(bufnr)
  local fingerprint = buffer_fingerprint(lines)
  local previous = state.file_fingerprints[ctx.absolute_path]
  local comments = scope_state.data.comments

  if previous == fingerprint then
    return scope_state
  end

  local changed = false
  for _, comment in ipairs(comments) do
    if comment.absolute_path == ctx.absolute_path then
      if reconcile_comment(comment, lines) then
        changed = true
      end
    end
  end

  if changed then
    local ok, err = storage.save_scope(ctx.scope_root, scope_state.data)
    if not ok then
      vim.notify(err or "Failed to save review comments.", vim.log.levels.ERROR)
    end
  end

  state.file_fingerprints[ctx.absolute_path] = fingerprint
  return scope_state
end

local function scope_state_for_buffer(bufnr)
  local ctx, err = context.comment_context(bufnr)
  if not ctx then
    return nil, err
  end

  local scope_state = {
    scope_root = ctx.scope_root,
    data = storage.load_scope(ctx.scope_root),
  }

  reconcile_buffer_state(bufnr or 0, scope_state, ctx)
  return {
    ctx = ctx,
    scope_state = scope_state,
  }
end

---@return LocalReviewComment, boolean
local function upsert_comment(scope_state, ctx, line, body)
  local comments = scope_state.data.comments
  local existing = find_comment_at_line(comments, ctx.absolute_path, line)

  local timestamp = now()
  local lines = buffer_lines(ctx.bufnr)
  local resolved_line = clamp_line(line, lines)
  if existing then
    existing.body = body
    existing.updated_at = timestamp
    existing.absolute_path = ctx.absolute_path
    apply_anchor(existing, lines, resolved_line)
    return existing, true
  end

  local filetype = vim.bo[ctx.bufnr].filetype or ""
  local source_kind = filetype:match("^Diffview") and "diffview" or "buffer"
  local comment = {
    id = tostring(hrtime()),
    absolute_path = ctx.absolute_path,
    body = body,
    created_at = timestamp,
    updated_at = timestamp,
    source_kind = source_kind,
    source_meta = {},
    stale = false,
  }

  apply_anchor(comment, lines, resolved_line)
  table.insert(comments, comment)
  return comment, false
end

local function find_current_comment()
  local resolved, err = scope_state_for_buffer(0)
  if not resolved then
    vim.notify(err or "Failed to find the current review comment.", vim.log.levels.WARN)
    return nil
  end

  local line = current_line()
  local comment, index = find_comment_entry_at_line(resolved.scope_state.data.comments, resolved.ctx.absolute_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    scope_state = resolved.scope_state,
  }
end

local function find_line_comment(bufnr, line)
  local resolved, err = scope_state_for_buffer(bufnr)
  if not resolved then
    return nil, err
  end

  local comment, index = find_comment_entry_at_line(resolved.scope_state.data.comments, resolved.ctx.absolute_path, line)
  return {
    ---@type LocalReviewComment?
    comment = comment,
    index = index,
    ctx = resolved.ctx,
    scope_state = resolved.scope_state,
  }
end

local function comments_in_scope(scope_root)
  local data = storage.load_scope(scope_root)
  for _, comment in ipairs(data.comments) do
    ensure_comment_defaults(comment)
  end
  table.sort(data.comments, comment_sorter)
  return data.comments
end

local function comments_matching_path(target_path, kind)
  local matches = {}
  for _, scope in ipairs(storage.list_scopes()) do
    for _, comment in ipairs(scope.data.comments or {}) do
      ensure_comment_defaults(comment)
      if kind == "file" then
        if comment.absolute_path == target_path then
          table.insert(matches, comment)
        end
      elseif context.is_within(target_path, comment.absolute_path) then
        table.insert(matches, comment)
      end
    end
  end

  table.sort(matches, comment_sorter)
  return matches
end

local function remove_matching_comments(target_path, kind)
  local changed_scopes = {}

  for _, scope in ipairs(storage.list_scopes()) do
    local kept = {}
    local remove_ids = {}
    local changed = false
    for _, comment in ipairs(scope.data.comments or {}) do
      local matches = false
      if kind == "file" then
        matches = comment.absolute_path == target_path
      else
        matches = context.is_within(target_path, comment.absolute_path)
      end

      if matches then
        changed = true
        remove_ids[comment.id] = true
      else
        table.insert(kept, comment)
      end
    end

    if changed then
      changed_scopes[#changed_scopes + 1] = {
        scope_root = scope.scope_root,
        data = {
          scope_root = scope.scope_root,
          comments = kept,
          removed_ids = remove_ids,
        },
      }
    end
  end

  return changed_scopes
end

function M.status_label(comment)
  if comment and comment.stale then
    return "stale"
  end
  return nil
end

function M.list_scope_comments(scope_root)
  return comments_in_scope(scope_root)
end

function M.list_comments_in_path(path)
  local target = path
  if target == nil or target == "" then
    target = context.default_export_root()
  end

  local kind, normalized_or_err = context.path_kind(target)
  if not kind then
    return nil, normalized_or_err
  end

  return comments_matching_path(normalized_or_err, kind), normalized_or_err, kind
end

function M.comments_for_buffer(bufnr, opts)
  local resolved, err = scope_state_for_buffer(bufnr or 0)
  if not resolved then
    if not (opts and opts.silent) then
      vim.notify(err or "Failed to load comments for the current buffer.", vim.log.levels.WARN)
    end
    return {}
  end

  local matches = {}
  for _, comment in ipairs(comments_in_scope(resolved.ctx.scope_root)) do
    if comment.absolute_path == resolved.ctx.absolute_path then
      table.insert(matches, comment)
    end
  end
  return matches
end

function M.get_line_state(bufnr, line)
  local result, err = find_line_comment(bufnr or 0, line)
  if not result then
    vim.notify(err or "Failed to find a review comment for the current line.", vim.log.levels.WARN)
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
    line_state.scope_state,
    line_state.ctx,
    line_state.comment and line_state.comment.anchor.line_number or current_line(),
    trimmed
  )
  local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
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
      local removed = table.remove(line_state.scope_state.data.comments, line_state.index)
      local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data, {
        remove_ids = { [removed.id] = true },
      })
      if not ok then
        return nil, err
      end
      return "deleted"
    end

    return "noop"
  end

  local _, updated = upsert_comment(line_state.scope_state, line_state.ctx, line, trimmed)
  local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data)
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

  local removed = table.remove(line_state.scope_state.data.comments, line_state.index)
  local ok, err = persist_scope_state(line_state.ctx.scope_root, line_state.scope_state.data, {
    remove_ids = { [removed.id] = true },
  })
  if not ok then
    return nil, err
  end
  return "deleted"
end

local function prompt_display_path(ctx)
  local repo_root = context.repo_root(ctx.absolute_path)
  if repo_root then
    return context.relative_path(repo_root, ctx.absolute_path) or ctx.absolute_path
  end

  return ctx.absolute_path
end

function M.prompt_for_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  local line = current_line()
  local prompt = result.comment and "Edit review comment" or "Add review comment"
  local display_path = prompt_display_path(result.ctx)

  vim.ui.input({
    prompt = string.format("%s (%s:%d): ", prompt, display_path, line),
    default = result.comment and result.comment.body or "",
  }, function(input)
    if input == nil then
      return
    end

    local trimmed = vim.trim(input)
    if trimmed == "" then
      vim.notify("Comment cannot be empty.", vim.log.levels.WARN)
      return
    end

    local _, updated = upsert_comment(result.scope_state, result.ctx, line, trimmed)
    local ok, err = persist_scope_state(result.ctx.scope_root, result.scope_state.data)
    if not ok then
      vim.notify(err or "Failed to save the review comment.", vim.log.levels.ERROR)
      return
    end
    vim.notify(updated and "Review comment updated." or "Review comment added.", vim.log.levels.INFO)
  end)
end

function M.delete_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  if result.index == nil then
    vim.notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end

  local removed = table.remove(result.scope_state.data.comments, result.index)
  local ok, err = persist_scope_state(result.ctx.scope_root, result.scope_state.data, {
    remove_ids = { [removed.id] = true },
  })
  if not ok then
    vim.notify(err or "Failed to delete the review comment.", vim.log.levels.ERROR)
    return
  end
  vim.notify("Review comment deleted.", vim.log.levels.INFO)
end

function M.jump(direction)
  local comments = M.comments_for_buffer(0)
  if #comments == 0 then
    vim.notify("No review comments in the current buffer.", vim.log.levels.INFO)
    return
  end

  local line = current_line()
  table.sort(comments, function(a, b)
    return a.anchor.line_number < b.anchor.line_number
  end)

  local target
  if direction > 0 then
    for _, comment in ipairs(comments) do
      if comment.anchor.line_number > line then
        target = comment
        break
      end
    end
    target = target or comments[1]
  else
    for index = #comments, 1, -1 do
      if comments[index].anchor.line_number < line then
        target = comments[index]
        break
      end
    end
    target = target or comments[#comments]
  end

  local max_line = math.max(vim.api.nvim_buf_line_count(0), 1)
  local target_line = math.max(1, math.min(target.anchor.line_number, max_line))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  if target.stale then
    vim.notify("Jumped to a stale review comment.", vim.log.levels.WARN)
  end
end

function M.clear_path(path, opts)
  local silent = opts and opts.silent
  local comments_in_path, target_path, kind = M.list_comments_in_path(path)
  if not comments_in_path then
    vim.notify(target_path or "Failed to resolve comment scope.", vim.log.levels.WARN)
    return
  end

  if #comments_in_path == 0 then
    if not silent then
      vim.notify("No review comments found for the selected path.", vim.log.levels.INFO)
    end
    return
  end

  local changed_scopes = remove_matching_comments(target_path, kind)
  for _, scope in ipairs(changed_scopes) do
    local ok, err = persist_scope_state(scope.scope_root, scope.data)
    if not ok then
      vim.notify(err or "Failed to clear review comments.", vim.log.levels.ERROR)
      return
    end
  end

  if not silent then
    vim.notify("Cleared review comments for selected path.", vim.log.levels.INFO)
  end
end

function M.clear_repo()
  M.clear_path()
end

return M
