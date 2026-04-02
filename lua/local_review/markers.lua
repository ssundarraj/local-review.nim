local M = {}

local namespace = vim.api.nvim_create_namespace("local-review-markers")

local function marker_opts()
  return require("local_review").get_opts()
end

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  local comments = require("local_review.comments").comments_for_buffer(bufnr)
  local opts = marker_opts()
  local max_line = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
  for index, comment in ipairs(comments) do
    local line = math.max(1, math.min(comment.line or 1, max_line))
    vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, {
      sign_text = opts.marker_text,
      sign_hl_group = opts.marker_hl,
      priority = 10 + index,
    })
  end
end

return M
