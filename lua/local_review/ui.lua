local M = {}

local comments = require("local_review.comments")

local state = {
  bufnr = nil,
  winid = nil,
  source_bufnr = nil,
  source_line = nil,
  initial_body = "",
  augroup = nil,
  closing = false,
}

local function is_valid_buffer(bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_window(winid)
  return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

local function is_open()
  return is_valid_buffer(state.bufnr) and is_valid_window(state.winid)
end

local function current_body()
  if not is_valid_buffer(state.bufnr) then
    return ""
  end

  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"))
end

local function is_dirty()
  return current_body() ~= vim.trim(state.initial_body or "")
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function cleanup()
  state.bufnr = nil
  state.winid = nil
  state.source_bufnr = nil
  state.source_line = nil
  state.initial_body = ""
  state.augroup = nil
  state.closing = false
end

local function close_window()
  if is_valid_window(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
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
    notify(err, vim.log.levels.ERROR)
    return false
  end

  if notify_result and result == "created" then
    notify("Review comment added.")
  elseif notify_result and result == "updated" then
    notify("Review comment updated.")
  elseif notify_result and result == "deleted" then
    notify("Review comment deleted.")
  end

  state.initial_body = current_body()
  if is_valid_buffer(state.bufnr) then
    vim.bo[state.bufnr].modified = false
  end
  return true
end

function M.close_active(opts)
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

local function float_size(body)
  local lines = vim.split(body == "" and " " or body, "\n", { plain = true })
  local width = 60
  for _, line in ipairs(lines) do
    width = math.max(width, math.min(120, #line + 4))
  end

  local max_width = math.min(120, math.max(60, math.floor(vim.o.columns * 0.9)))
  local max_height = math.max(8, vim.o.lines - 8)
  return {
    width = math.min(width, max_width),
    height = math.min(math.max(8, #lines + 2), max_height),
  }
end

local function set_float_keymaps(bufnr)
  local function map(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
  end

  map({ "n", "i" }, "<C-s>", function()
    M.save_active()
  end, "Local Review: Save")

  map("n", "q", function()
    M.close_active()
  end, "Local Review: Close")
end

local function attach_lifecycle_autocmds(bufnr, winid)
  local group = vim.api.nvim_create_augroup("local-review-float-" .. bufnr, { clear = true })
  state.augroup = group

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      persist()
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

      if is_dirty() then
        vim.schedule(function()
          M.close_active()
        end)
      else
        cleanup()
      end
    end,
  })
end

function M.open_current_line()
  if not M.close_active() then
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_line = vim.api.nvim_win_get_cursor(0)[1]
  local line_state = comments.get_line_state(source_bufnr, source_line)
  if not line_state then
    return
  end

  local body = line_state.comment and line_state.comment.body or ""
  local size = float_size(body)
  local bufnr = vim.api.nvim_create_buf(false, true)

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = "markdown"

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, body == "" and { "" } or vim.split(body, "\n", { plain = true }))

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - size.height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - size.width) / 2)),
    width = size.width,
    height = size.height,
    style = "minimal",
    border = "rounded",
    title = " Review Comment ",
    title_pos = "center",
  })

  state.bufnr = bufnr
  state.winid = winid
  state.source_bufnr = source_bufnr
  state.source_line = source_line
  state.initial_body = body
  state.closing = false

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true

  set_float_keymaps(bufnr)
  attach_lifecycle_autocmds(bufnr, winid)
end

return M
