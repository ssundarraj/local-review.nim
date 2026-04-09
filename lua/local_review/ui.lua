local M = {}

local comments = require("local_review.comments")

local namespace = vim.api.nvim_create_namespace("local-review-ui")
local placeholder_namespace = vim.api.nvim_create_namespace("local-review-ui-placeholder")
local placeholder_text = "Write a review comment..."

local state = {
  editor_bufnr = nil,
  editor_winid = nil,
  source_bufnr = nil,
  source_winid = nil,
  source_line = nil,
  anchor_row = nil,
  extmark_id = nil,
  initial_body = "",
  reserved_height = 0,
  closing = false,
}

local function is_valid_buffer(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_window(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

local function is_open()
  return is_valid_buffer(state.editor_bufnr) and is_valid_window(state.editor_winid)
end

local function body_lines(body)
  local text = body or ""
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

local function editor_buffer_name(source_bufnr, source_line)
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  if source_name == "" then
    source_name = string.format("buffer-%d", source_bufnr)
  end

  return string.format("local-review://comment/%s:%d", source_name, source_line)
end

local function current_body()
  if not is_valid_buffer(state.editor_bufnr) then
    return ""
  end

  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.editor_bufnr, 0, -1, false), "\n"))
end

local function is_dirty()
  return current_body() ~= vim.trim(state.initial_body or "")
end

local function update_placeholder(bufnr)
  if not is_valid_buffer(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, placeholder_namespace, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local has_content = vim.trim(table.concat(lines, "\n")) ~= ""
  if has_content then
    return
  end

  vim.api.nvim_buf_set_extmark(bufnr, placeholder_namespace, 0, 0, {
    virt_text = { { placeholder_text, "Comment" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })
end

local function clear_inline_space()
  if is_valid_buffer(state.source_bufnr) and state.extmark_id ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, state.source_bufnr, namespace, state.extmark_id)
  end
  state.extmark_id = nil
end

local function cleanup()
  clear_inline_space()
  state.editor_bufnr = nil
  state.editor_winid = nil
  state.source_bufnr = nil
  state.source_winid = nil
  state.source_line = nil
  state.anchor_row = nil
  state.initial_body = ""
  state.reserved_height = 0
  state.closing = false
end

local function close_window()
  if is_valid_window(state.editor_winid) then
    pcall(vim.api.nvim_win_close, state.editor_winid, true)
  end
  cleanup()
end

local function persist(opts)
  if state.source_bufnr == nil or state.source_line == nil then
    return true
  end

  local notify_result = not (opts and opts.silent)
  local result, err = comments.set_line_comment(state.source_bufnr, state.source_line, current_body())
  if not result then
    vim.notify(err or "Failed to save the review comment.", vim.log.levels.ERROR)
    return false
  end

  if notify_result and result == "created" then
    vim.notify("Review comment added.", vim.log.levels.INFO)
  elseif notify_result and result == "updated" then
    vim.notify("Review comment updated.", vim.log.levels.INFO)
  elseif notify_result and result == "deleted" then
    vim.notify("Review comment deleted.", vim.log.levels.INFO)
  end

  state.initial_body = current_body()
  if is_valid_buffer(state.editor_bufnr) then
    vim.bo[state.editor_bufnr].modified = false
  end
  return true
end

function M.close_active()
  if not is_open() then
    cleanup()
    return true
  end

  if is_dirty() and not persist({ silent = true }) then
    return false
  end

  state.closing = true
  close_window()
  return true
end

function M.save_active()
  if not is_open() then
    return
  end

  persist()
end

local function text_column_offset(winid)
  return vim.fn.getwininfo(winid)[1].textoff
end

local function inline_dimensions(lines, source_winid, anchor_row)
  local win_width = vim.api.nvim_win_get_width(source_winid)
  local max_width = math.min(120, math.max(60, win_width - text_column_offset(source_winid)))
  local width = 60
  for _, line in ipairs(lines) do
    width = math.max(width, math.min(max_width, #line + 2))
  end

  local row = anchor_row or (vim.fn.winline() + 1)
  local available_height = math.max(6, vim.api.nvim_win_get_height(source_winid) - row - 1)
  local height = math.min(math.max(3, #lines), available_height)

  return {
    width = width,
    height = height,
  }
end

local function reserve_inline_space(bufnr, line, height)
  local virt_lines = {}
  for _ = 1, height do
    virt_lines[#virt_lines + 1] = { { " ", "Normal" } }
  end

  state.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_leftcol = true,
    hl_mode = "combine",
  })
  state.reserved_height = height
end

local function update_layout()
  if not is_open() or not is_valid_window(state.source_winid) or state.source_line == nil then
    return
  end

  local size = inline_dimensions(
    vim.api.nvim_buf_get_lines(state.editor_bufnr, 0, -1, false),
    state.source_winid,
    state.anchor_row
  )
  local reserved_height = size.height + 3

  clear_inline_space()
  reserve_inline_space(state.source_bufnr, state.source_line, reserved_height)

  vim.api.nvim_win_set_config(state.editor_winid, {
    relative = "win",
    win = state.source_winid,
    row = state.anchor_row or (vim.fn.winline() + 1),
    col = text_column_offset(state.source_winid) + 1,
    width = size.width,
    height = size.height,
  })
end

local function set_editor_keymaps(bufnr)
  local function map(modes, lhs, rhs, desc)
    if lhs == nil or lhs == "" then
      return
    end

    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
  end

  local opts = require("local_review").get_opts()
  for _, keymap in ipairs(opts.comment_close_keys or {}) do
    map(keymap.modes, keymap.key, function()
      M.close_active()
    end, "Local Review: Close")
  end
end

local function attach_editor_autocmds(bufnr, winid)
  local group = vim.api.nvim_create_augroup("local-review-inline-" .. bufnr, { clear = true })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      update_placeholder(bufnr)
      update_layout()
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      persist()
      update_placeholder(bufnr)
      update_layout()
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if tonumber(event.match) ~= winid then
        return
      end

      if state.closing then
        cleanup()
        return
      end

      vim.schedule(function()
        M.close_active()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      if not is_valid_window(winid) or vim.api.nvim_get_current_win() ~= winid or state.closing then
        return
      end

      vim.schedule(function()
        M.close_active()
      end)
    end,
  })
end

function M.open_current_line()
  if not M.close_active() then
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_winid = vim.api.nvim_get_current_win()
  local source_line = vim.api.nvim_win_get_cursor(source_winid)[1]
  local line_state = comments.get_line_state(source_bufnr, source_line)
  if not line_state then
    return
  end

  local lines = body_lines(line_state.comment and line_state.comment.body or "")
  local title = " Review Comment "
  if line_state.comment and line_state.comment.stale then
    title = " Review Comment [stale] "
  end
  local size = inline_dimensions(lines, source_winid, state.anchor_row)
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_name(bufnr, editor_buffer_name(source_bufnr, source_line))

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  state.editor_bufnr = bufnr
  state.source_bufnr = source_bufnr
  state.source_winid = source_winid
  state.source_line = source_line
  state.anchor_row = vim.fn.winline() + 1
  state.initial_body = table.concat(lines, "\n")
  state.reserved_height = 0
  state.closing = false

  size = inline_dimensions(lines, source_winid, state.anchor_row)
  reserve_inline_space(source_bufnr, source_line, size.height + 3)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = source_winid,
    row = state.anchor_row,
    col = text_column_offset(source_winid) + 1,
    width = size.width,
    height = size.height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "left",
    noautocmd = true,
  })

  state.editor_winid = winid

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  set_editor_keymaps(bufnr)
  attach_editor_autocmds(bufnr, winid)
  update_placeholder(bufnr)
  if line_state.comment and line_state.comment.stale then
    vim.notify("This review comment is stale and may no longer point at the original code.", vim.log.levels.WARN)
  end
end

return M
