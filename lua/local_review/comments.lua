local M = {}

local context = require("local_review.context")
local storage = require("local_review.storage")

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function hrtime()
  local uv = vim.uv or vim.loop
  return uv.hrtime()
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
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
  local signs = require("local_review.signs")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        local root = context.repo_root(path)
        if root == repo_root then
          signs.refresh(bufnr)
        end
      end
    end
  end
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

local function upsert_comment(repo_state, ctx, line, body)
  local comments = repo_state.data.comments
  local existing

  for _, comment in ipairs(comments) do
    if comment.relative_path == ctx.relative_path and comment.line == line then
      existing = comment
      break
    end
  end

  local timestamp = now()
  if existing then
    existing.body = body
    existing.updated_at = timestamp
    existing.absolute_path = ctx.absolute_path
    existing.repo_root = ctx.repo_root
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
  }

  table.insert(comments, comment)
  return comment, false
end

local function find_current_comment()
  local ctx, err = context.comment_context(0)
  if not ctx then
    notify(err, vim.log.levels.WARN)
    return nil
  end

  local repo_state = loaded_repo()
  if not repo_state then
    return nil
  end

  local line = current_line()
  for index, comment in ipairs(repo_state.data.comments) do
    if comment.relative_path == ctx.relative_path and comment.line == line then
      return {
        comment = comment,
        index = index,
        ctx = ctx,
        repo_state = repo_state,
      }
    end
  end

  return {
    comment = nil,
    index = nil,
    ctx = ctx,
    repo_state = repo_state,
  }
end

local function find_line_comment(bufnr, line)
  local ctx, err = context.comment_context(bufnr)
  if not ctx then
    return nil, err
  end

  local repo_state = {
    repo_root = ctx.repo_root,
    data = storage.load_repo(ctx.repo_root),
  }

  for index, comment in ipairs(repo_state.data.comments) do
    if comment.relative_path == ctx.relative_path and comment.line == line then
      return {
        comment = comment,
        index = index,
        ctx = ctx,
        repo_state = repo_state,
      }
    end
  end

  return {
    comment = nil,
    index = nil,
    ctx = ctx,
    repo_state = repo_state,
  }
end

function M.list_repo_comments(repo_root)
  local data = storage.load_repo(repo_root)
  table.sort(data.comments, comment_sorter)
  return data.comments
end

function M.comments_for_buffer(bufnr)
  local ctx = context.comment_context(bufnr)
  if not ctx then
    return {}
  end

  local comments = M.list_repo_comments(ctx.repo_root)
  local matches = {}
  for _, comment in ipairs(comments) do
    if comment.relative_path == ctx.relative_path then
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

  local _, updated = upsert_comment(line_state.repo_state, line_state.ctx, line_state.comment and line_state.comment.line or line_state.ctx.line or current_line(), trimmed)
  storage.save_repo(line_state.ctx.repo_root, line_state.repo_state.data)
  refresh_repo_buffers(line_state.ctx.repo_root)
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
      storage.save_repo(line_state.ctx.repo_root, line_state.repo_state.data)
      refresh_repo_buffers(line_state.ctx.repo_root)
      return "deleted"
    end

    return "noop"
  end

  local _, updated = upsert_comment(line_state.repo_state, line_state.ctx, line, trimmed)
  storage.save_repo(line_state.ctx.repo_root, line_state.repo_state.data)
  refresh_repo_buffers(line_state.ctx.repo_root)
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
  storage.save_repo(line_state.ctx.repo_root, line_state.repo_state.data)
  refresh_repo_buffers(line_state.ctx.repo_root)
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
    storage.save_repo(result.ctx.repo_root, result.repo_state.data)
    refresh_repo_buffers(result.ctx.repo_root)
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
  storage.save_repo(result.ctx.repo_root, result.repo_state.data)
  refresh_repo_buffers(result.ctx.repo_root)
  notify("Review comment deleted.")
end

function M.show_current_line()
  local result = find_current_comment()
  if not result then
    return
  end

  if result.comment == nil then
    notify("No review comment on the current line.", vim.log.levels.INFO)
    return
  end

  notify(string.format("%s:%d\n%s", result.ctx.relative_path, result.comment.line, result.comment.body))
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

  vim.api.nvim_win_set_cursor(0, { target.line, 0 })
end

function M.clear_repo()
  local repo_state = loaded_repo()
  if not repo_state then
    return
  end

  repo_state.data.comments = {}
  storage.delete_repo(repo_state.repo_root)
  refresh_repo_buffers(repo_state.repo_root)
  notify("Cleared review comments for current repo.")
end

return M
